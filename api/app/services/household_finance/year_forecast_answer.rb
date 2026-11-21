module HouseholdFinance
  # Mia's answers to forecast and saved-bill questions, worded from Rails facts. Nothing changes.
  # Only plain questions about the year or about saved due dates: a worry, a report of a payment or a request
  # for help choosing what to pay goes to the answers built for those.
  class YearForecastAnswer
    NOT_A_FORECAST_QUESTION = /\b(?:pay first|payday|scared?|scares?|scary|afraid|worried|stress\w*|behind|overwhelm\w*|can(?:no|['’])?t (?:pay|afford)|short on|late fees?|what (?:do|should) (?:i|we) do|help me)\b/i
    YEAR_PATTERN = Regexp.union(
      /\b(?:will|would|can|do|are|is)\s+(?:we|i|our money|my money)\b.{0,40}\b(?:make it|get|last|stretch)\s+(?:all the way\s+)?(?:through|to|until|till)\s+(?:the (?:end of the )?year|december|year[- ]end)\b/i,
      /\b(?:which|what) month\b.{0,40}\bshort\b/i,
      /\b(?:be|run|running|go|come up)\s+short\b.{0,40}\b(?:by|before|in|through)\s+(?:december|the end of the year|year[- ]end)\b/i,
      /\b(?:be|run|running|go|come up)\s+short\b.{0,20}\bthis year\b/i,
      /\b(?:year[- ]ahead|cash forecast|(?:my|our|the) (?:year|money) forecast|forecast (?:for|through) (?:the year|december))\b/i
    )
    NEXT_BILL_PATTERN = /\b(?:next|upcoming)\s+(?:big(?:gest)?\s+|large(?:st)?\s+|major\s+)?bill\b/i
    DUE_PATTERN = /\b(?:what|which)(?:['’]s|\s+is|\s+bills?\s+(?:are|is))?\s+(?:\w+\s+){0,2}?due\s+(this month|next month|in\s+(?:#{MonthTerms.pattern}))\b/i
    BIG_BILL_DAYS = 60
    LOOK_AHEAD_MONTHS = 12
    LIST_LIMIT = 8

    def self.question?(message)
      text = message.to_s.squish
      return false if text.match?(NOT_A_FORECAST_QUESTION) || MiaCoachAnswerer.spend_report_text?(text)
      return false unless text.include?("?") || text.match?(/\A(?:will|would|can|do|are|is|which|what|when|show|tell)\b/i)

      text.match?(YEAR_PATTERN) || text.match?(NEXT_BILL_PATTERN) || text.match?(DUE_PATTERN)
    end

    # forecast: the plan's year forecast, or a callable returning it, so the plan is read once and only for a year question.
    def initialize(household, message, forecast: nil, today: Date.current)
      @household, @message, @forecast, @today = household, message.to_s.squish, forecast, today
    end

    def call
      return unless self.class.question?(@message)
      return year_answer if @message.match?(YEAR_PATTERN)
      return next_big_bill_answer if @message.match?(NEXT_BILL_PATTERN)

      due_answer(@message[DUE_PATTERN, 1].downcase)
    end

    private

    def forecast
      @forecast_data ||= (@forecast.respond_to?(:call) ? @forecast.call : @forecast) || AnnualBudgetManager.new(@household).read_only_plan_data.fetch(:year_forecast)
    end

    def year_answer
      short = forecast[:first_short_month]
      start = forecast[:starting_note]
      if short
        estimate = short[:includes_estimates] ? " Some of that month’s amounts are estimates." : ""
        "#{short[:label]} is the first month that runs short: cash would end about #{Money.plain(-short[:ending_cents])} below zero. Costs that month include #{short[:reasons].to_sentence}.#{estimate} #{start}"
      elsif forecast[:status] == "no_short_month"
        last = forecast[:months].last
        "No month runs short through December in this plan; December would end with about #{Money.plain(last[:ending_cents])}. #{start}"
      else
        missing = Array(forecast[:missing])
        needed = missing.any? ? " Still needed: #{missing.to_sentence}." : ""
        "I can’t tell yet whether you’ll make it through December.#{forecast[:starting_cash_cents].nil? ? " #{start}" : ''}#{needed}"
      end.strip
    end

    # "Big" is the largest saved bill due in the next 60 days: the one to get ready for. With nothing due that soon,
    # the next saved bill in the coming year.
    def next_big_bill_answer
      soon = occurrences(@today, @today + BIG_BILL_DAYS)
      later = occurrences(@today, @today >> LOOK_AHEAD_MONTHS).first
      text = if soon.any?
        "Your biggest bill due in the next #{BIG_BILL_DAYS} days is #{line(*soon.max_by { |bill, date| [ bill.amount_cents, -date.jd ] })}."
      elsif later
        "Nothing you saved is due in the next #{BIG_BILL_DAYS} days. The next saved bill is #{line(*later)}."
      else
        "You have no saved bills due in the next #{LOOK_AHEAD_MONTHS} months."
      end
      "#{text}#{awaiting_note} #{footer}"
    end

    def due_answer(period)
      month = case period
      when "this month" then @today.beginning_of_month
      when "next month" then @today.next_month.beginning_of_month
      else
        number = MonthTerms.number(period.delete_prefix("in").strip)
        year = MonthTerms.explicit_year(@message) || (number < @today.month ? @today.year + 1 : @today.year)
        Date.new(year, number, 1)
      end
      name = month.year == @today.year ? month.strftime("%B") : month.strftime("%B %Y")
      due = occurrences(month, month.end_of_month)
      text = if due.any?
        shown = due.first(LIST_LIMIT).map { |bill, date| line(bill, date) }
        more = due.length > LIST_LIMIT ? "; and #{due.length - LIST_LIMIT} more in Budget" : ""
        "Due in #{name}: #{shown.join('; ')}#{more}."
      else
        "You have no saved bills due in #{name}."
      end
      awaiting = month == @today.beginning_of_month ? awaiting_note : ""
      "#{text}#{awaiting} #{footer}"
    end

    def footer = "Debt minimums aren’t in this list; they still count from My Money. Only the bills you saved are here, so anything else is unknown. Nothing changed."

    def line(bill, date)
      details = [ (bill.estimate? ? "estimated" : nil), (bill.must_pay? ? "must pay" : nil) ].compact
      "#{bill.name}, #{Money.plain(bill.amount_cents)}, due #{long(date)}#{details.any? ? " (#{details.join(', ')})" : ''}"
    end

    def long(date) = date.year == @today.year ? date.strftime("%B %-d") : date.strftime("%B %-d, %Y")

    def awaiting_note
      awaiting = bills.select { |bill| bill.awaiting_answer?(@today) }
      return "" if awaiting.empty?
      " Past its date and not marked paid: #{awaiting.map { |bill| "#{bill.name}, #{Money.plain(bill.amount_cents)}, due #{long(bill.due_on)}" }.join('; ')}. If it was paid, mark it paid in Budget; until then it still counts."
    end

    def occurrences(from, to)
      bills.reject { |bill| bill.awaiting_answer?(@today) }
        .flat_map { |bill| bill.due_dates(from, to).map { |date| [ bill, date ] } }
        .sort_by { |bill, date| [ date, -bill.amount_cents, bill.id ] }
    end

    def bills = @bills ||= @household.bills.current_picture.unpaid.order(:due_on, :id).to_a
  end
end
