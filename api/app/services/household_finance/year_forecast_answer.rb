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
    # A purchase scenario ("Can I buy a $500 TV and still make it through the year?") needs purchase analysis:
    # the plain forecast doesn't include the purchase.
    PURCHASE_SCENARIO = /\b(?:buy|buying|purchas\w*|afford|book|booking|order)\b|\bspend(?:ing)?\s+(?:\$|about\s+\$|around\s+\$)?\d/i
    NEXT_BILL_PATTERN = /\b(?:next|upcoming)\s+(?:big(?:gest)?\s+|large(?:st)?\s+|major\s+)?bill\b/i
    DUE_PATTERN = /\b(?:what|which)(?:['’]s|\s+is|\s+bills?\s+(?:are|is))?\s+(?:\w+\s+){0,2}?due\s+(this month|next month|in\s+(?:#{MonthTerms.pattern}))\b/i
    BIG_BILL_DAYS = 60
    LOOK_AHEAD_MONTHS = 12
    LIST_LIMIT = 8

    def self.question?(message)
      text = message.to_s.squish
      return false if text.match?(NOT_A_FORECAST_QUESTION) || text.match?(PURCHASE_SCENARIO) || MiaCoachAnswerer.spend_report_text?(text)
      # A write ("Change my income to $4,000, and will we make it?") is drafted first, and leaving a job is an
      # Optionality runway scenario: the plain forecast includes neither change.
      return false if MiaCoachAnswerer.explicit_write_request?(text) || text.match?(MiaCoachAnswerer::TRANSITION_INTENT_PATTERN)
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
      asked = MonthTerms.explicit_year(@message) || @message[/\b(?:through|until|till|to|by|in|of)\s+(20\d{2})\b(?!\s*(?:dollars|bucks))/i, 1]&.to_i
      if asked && asked != @today.year
        return "Your cash forecast runs only through December #{@today.year}, so I can’t say yet how #{asked} ends. Nothing changed."
      end
      short = forecast[:first_short_month]
      start = forecast[:starting_note]
      if short
        "#{short[:label]} is the first month that runs short: cash would end about #{Money.plain(-short[:ending_cents])} below zero. Costs that month include #{short[:reasons].to_sentence}.#{estimate_note} #{start}"
      elsif forecast[:status] == "no_short_month"
        last = forecast[:months].last
        "No month runs short through December in this plan; December would end with about #{Money.plain(last[:ending_cents])}.#{estimate_note} #{start}"
      else
        missing = Array(forecast[:missing])
        needed = missing.any? ? " Still needed: #{missing.to_sentence}." : ""
        "I can’t tell yet whether you’ll make it through December.#{forecast[:starting_cash_cents].nil? ? " #{start}" : ''}#{needed}"
      end.strip
    end

    # Which estimates the answer rests on, in plain words, so "no month runs short" is never read as certain.
    def estimate_note
      reasons = Array(forecast[:estimate_reasons])
      flagged = forecast[:first_short_month]&.dig(:includes_estimates) || Array(forecast[:months]).any? { |month| month[:includes_estimates] }
      return " This rests on estimates: #{reasons.to_sentence}." if reasons.any?
      flagged ? " Some of these amounts are estimates." : ""
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
      due = (occurrences(month, month.end_of_month) + debt_occurrences(month)).sort_by do |item, date|
        debt = item.is_a?(Hash)
        [ date, -(debt ? item[:amount_cents] : item.amount_cents), debt ? 1 : 0, debt ? 0 : item.id ]
      end
      text = if due.any?
        shown = due.first(LIST_LIMIT).map { |item, date| item.is_a?(Hash) ? debt_line(item, date) : line(item, date) }
        more = due.length > LIST_LIMIT ? "; and #{due.length - LIST_LIMIT} more in Budget" : ""
        "Due in #{name}: #{shown.join('; ')}#{more}."
      else
        "You have no saved bills due in #{name}."
      end
      awaiting = month == @today.beginning_of_month ? "#{awaiting_note}#{owed_now_note}" : ""
      "#{text}#{awaiting} #{footer}"
    end

    def footer
      return "Debt minimums aren’t in this list; they still count from My Money. Only the bills you saved are here, so anything else is unknown. Nothing changed." unless dated_debts.any?

      "Debt payments with a saved due day are listed; any without one still count from My Money. Only the bills you saved are here, so anything else is unknown. Nothing changed."
    end

    # Dated minimums from the year forecast's own debt schedule, so this list and the forecast always agree: a
    # catch-up that pays off a balance leaves no minimum after it.
    def debt_occurrences(month)
      debt_schedule_items(month).reject { |item| item[:past_due] || item[:undated] }.map { |item| [ item, Date.iso8601(item[:due_on]) ] }
    end

    # The forecast's scheduled debt payments for a month, walking from this month so earlier payments lower each
    # balance first. A month before this one has none.
    def debt_schedule_items(month)
      @debt_schedule_items ||= {}
      @debt_schedule_items[month] ||= begin
        start = @today.beginning_of_month
        schedule = YearForecastDebtSchedule.new(@household, DebtPortfolio.new(@household), @today)
        items = []
        cursor = start
        while cursor <= month
          items = schedule.items(cursor, cursor.end_of_month, cursor, first_month: cursor == start)
          cursor = cursor.next_month
        end
        items
      end
    end

    def dated_debts
      @dated_debts ||= if DebtPortfolio.new(@household).mode == "individual"
        @household.debts.active.order(:id).select { |debt| debt.due_day && debt.minimum_payment_known? && debt.minimum_payment_cents.positive? }
      else
        []
      end
    end

    def debt_line(item, date) = "#{item[:name]} payment, #{Money.plain(item[:amount_cents])}, due #{long(date)} (from My Money)"

    # Past-due amounts on debts and bills: owed now, once, on top of this month's payments.
    def owed_now_note
      items = debt_schedule_items(@today.beginning_of_month).select { |item| item[:past_due] }.map { |item| "#{item[:name]}, #{Money.plain(item[:amount_cents])}" } +
        bills.select { |bill| bill.past_due_owed?(@today) }.map { |bill| "#{bill.name}, #{Money.plain(bill.past_due_cents)}" }
      return "" if items.empty?

      " Past due and owed now: #{items.join('; ')}. Each counts once this month, on top of the payments above."
    end

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
