module HouseholdFinance
  # The debt payments the year forecast counts each month, from My Money.
  # - Past due: owed now, once, in the forecast's first month. It is part of the debt's balance, so it is never more
  #   than the balance and it lowers what later minimums can pay.
  # - Tracked one by one with a saved due day: the minimum counts on that day (days 29 to 31 fall on a short month's
  #   last day), so a payment due on or before a midmonth balance date is already in that balance.
  # - No due day, or the one-total summary: the minimum counts in full and is marked undated, since it may already be
  #   paid this month.
  # A minimum never counts beyond what is left of a known balance.
  class YearForecastDebtSchedule
    SUMMARY_NAME = "Monthly debt payments".freeze

    def initialize(household, portfolio, today)
      @portfolio, @today = portfolio, today
      @debts = household.debts.active.current_picture.order(:id).to_a
      @arrears = DebtArrears.new(household)
      @remaining = @debts.select(&:balance_known?).to_h { |debt| [ debt.id, debt.balance_cents ] }
    end

    # from: the first day still to count (the day after a midmonth balance, otherwise the month's first day).
    def items(month_start, month_end, from, first_month:, past_due_only: false)
      list = first_month ? past_due_items([ [ from, @today ].max, month_end ].min) : []
      return list if past_due_only

      if @portfolio.mode == "summary"
        cents = @portfolio.monthly_minimum_cents
        list << item(SUMMARY_NAME, cents, nil, undated: true) if cents.positive?
        return list
      end

      @debts.each do |debt|
        next unless debt.minimum_payment_known? && debt.minimum_payment_cents.positive?

        date = debt.due_day && Date.new(month_start.year, month_start.month, [ debt.due_day, month_end.day ].min)
        next if date && date < from

        cents = pay!(debt, debt.minimum_payment_cents)
        list << item(debt.label, cents, date, undated: date.nil?) if cents.positive?
      end
      list
    end

    private

    def past_due_items(owed_on)
      @arrears.debts.filter_map do |debt|
        cents = pay!(debt, @arrears.catch_up_cents(debt))
        item(debt.label, cents, owed_on, undated: false, past_due: true) if cents.positive?
      end
    end

    # What this payment can be, given what is left of a known balance; an unknown balance cannot cap it.
    def pay!(debt, cents)
      return cents unless @remaining.key?(debt.id)

      paid = [ cents, @remaining.fetch(debt.id) ].min
      @remaining[debt.id] -= paid
      paid
    end

    def item(name, cents, date, undated:, past_due: false)
      { name: name, amount_cents: cents, due_on: date&.iso8601, undated: undated, past_due: past_due }
    end
  end
end
