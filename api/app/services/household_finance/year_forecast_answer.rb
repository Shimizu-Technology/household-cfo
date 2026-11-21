module HouseholdFinance
  class YearForecastAnswer
    def initialize(household, message)
      @household, @message = household, message.to_s
    end

    def call
      year_question = @message.match?(/(?:make it|through|forecast|short).*(?:year|December)|year.*(?:ahead|short|forecast)/i)
      bill_question = @message.match?(/next big bill|what.*due (?:in|this)|bills? due/i)
      return unless year_question || bill_question
      plan = AnnualBudgetManager.new(@household).read_only_plan_data
      forecast = plan.fetch(:year_forecast)
      if year_question
        short = forecast[:first_short_month]
        answer = if short
          "#{short[:label]} is the first month that runs short: #{Money.plain(-short[:ending_cents])}. Planned costs include #{short[:reasons].join(', ')}."
        elsif forecast[:status] == "no_short_month"
          "No month runs short through December in this plan."
        else
          "I cannot tell whether you will make it through the year yet. Some cash balances, income or spending are not known."
        end
        return "#{answer} #{forecast[:rule]}"
      end
      number = MonthTerms.detect_number(@message)
      date = Date.new(Date.current.year, number || Date.current.month, 1)
      bills = @household.bills.current_picture.to_a
      due = if number
        bills.filter_map { |bill| day = bill.due_in(date); [ bill, day ] if day }
      else
        (Date.current.month..12).flat_map do |month|
          bills.filter_map { |bill| day = bill.due_in(Date.new(Date.current.year, month, 1)); [ bill, day ] if day && day >= Date.current }
        end.sort_by { |bill, day| [ day, -bill.amount_cents ] }.first(1)
      end
      lines = due.map { |bill, day| "#{bill.name}: #{Money.plain(bill.amount_cents)}#{bill.estimate? ? ' estimated' : ''}, due #{day.strftime('%B %-d')}#{bill.must_pay? ? ', must pay' : ''}" }
      text = lines.any? ? lines.join("; ") : "No bills with saved due dates were found for that period."
      "#{text} Debt minimums are separate and still count; check My Money for their saved dates. These are only the bills you saved, so anything missing is unknown. Nothing changed."
    end
  end
end
