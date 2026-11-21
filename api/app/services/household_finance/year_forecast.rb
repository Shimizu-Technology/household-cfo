module HouseholdFinance
  # Cash at the end of each month through December. Every rule keeps a cost or income from counting twice:
  # - Opening cash is her checking, savings and cash balances, all known and all dated the same day: in the current
  #   month or the last day of the month before. Other dates leave cash unknown rather than guess what already happened.
  #   A balance dated a month's last day already includes that whole month, so the forecast starts with the next one.
  # - From a midmonth balance only what comes after that day counts for the rest of the month: income still expected,
  #   bills due after it, and what is left of each category's plan. Debt minimums still count in full because their due
  #   dates aren't saved, and the month says they may already be paid.
  # - Planned yearly costs and the surprise fund (sinking groups): set-asides move to her own savings, which is cash too.
  #   Saved bills count when due. The part of the monthly plan her saved bills don't cover (plan minus a twelfth of the
  #   category's bills over the next 12 months) still counts each month, so costs she hasn't saved as bills aren't lost.
  # - Other categories count the larger of their plan and their bills due that month; in the current month, spending
  #   already recorded counts when it is larger. Bills outside any category add. Debt minimums count once a month.
  # - A one-time bill she marked paid never counts. One past its date and not marked paid counts in the first forecast
  #   month until she answers.
  # - A month that rests on an estimate says which kind: estimated pay, estimated bill amounts, or debt payments that
  #   may already be paid.
  class YearForecast
    SINKING = %w[sinking_expected sinking_unexpected].freeze
    SPIKE_MINIMUM_CENTS = 10_000
    DEBT_WORD_STOPLIST = %w[the and for bill bills payment payments monthly pay due my our].freeze

    def initialize(household, year:, periods:, rows:, monthly_income:, actual_income:, income_sources: [], today: Date.current)
      @household, @year, @periods, @rows, @income, @actual, @sources, @today = household, year, periods, rows, monthly_income, actual_income, income_sources, today
    end

    ESTIMATED_PAY = "estimated pay for the rest of this month".freeze
    ESTIMATED_BILLS = "estimated bill amounts".freeze
    DEBT_MAY_BE_PAID = "debt payments that may already be paid this month".freeze

    def call
      first = [ Date.new(@year, 1, 1), @today.beginning_of_month ].max
      anchor, cash, starting_note = opening(first)
      # Dated the month's last day, the balance already holds that whole month: nothing of it is left to count.
      first = first.next_month if anchor && anchor == first.end_of_month && @periods.any? { |period| period.starts_on == first.next_month }
      starting = cash
      debts = DebtPortfolio.new(@household)
      bills = @household.bills.current_picture.order(:due_on, :id).to_a
      open_bills = bills.reject(&:paid_on)
      rows = @rows.select { |row| row[:active] }
      covered = covered_monthly(open_bills, rows, first)
      plan_known = rows.any? && debts.minimum_payment_known?
      months = @periods.select { |period| period.starts_on >= first }.sort_by(&:starts_on).map do |period|
        month_start, month_end = period.starts_on, period.starts_on.end_of_month
        index = month_start.month - 1
        current = month_start == @today.beginning_of_month
        midmonth = anchor if anchor && anchor.beginning_of_month == month_start
        closed = midmonth == month_end
        from = midmonth ? midmonth + 1 : month_start
        due = due_bills(open_bills, from, month_end, month_start == first)
        spent_after = midmonth ? spending_after(midmonth + 1, month_end) : {}
        counted = rows.to_h do |row|
          cell = row[:months][index]
          planned = Money.cents(cell[:planned])
          linked = due.select { |bill| bill[:budget_category_id] == row[:id] }.sum { |bill| bill[:amount_cents] }
          spent = current ? Money.cents(cell[:actual]) : 0
          after = spent_after.fetch(row[:id], 0)
          # Sinking groups: only the part of the plan her saved bills don't cover leaves, plus the bills when due.
          plan = SINKING.include?(row[:stack_key]) ? [ planned - covered.fetch(row[:id], 0), 0 ].max : planned
          due_extra = SINKING.include?(row[:stack_key]) ? linked : 0
          cents = if closed
            linked
          elsif midmonth
            [ [ plan - (spent - after), 0 ].max + due_extra, linked, after ].max
          else
            [ plan + due_extra, linked, spent ].max
          end
          [ row[:id], cents ]
        end
        allocations_known = rows.all? { |row| !row[:months][index][:allocation_missing] }
        known = plan_known && allocations_known
        outside = due.reject { |bill| counted.key?(bill[:budget_category_id]) }
        debt_cents = closed ? 0 : debts.monthly_minimum_cents
        out = counted.values.sum + outside.sum { |bill| bill[:amount_cents] } + debt_cents
        income, basis, approved = closed ? [ 0, "after_balance", nil ] : income_for(period, month_end, midmonth, current)
        opening_cents = cash
        cash = cash && income && known ? cash + income - out : nil
        reasons = due.sort_by { |bill| -bill[:amount_cents] }.map { |bill| bill[:name] }.uniq
        reasons = rows.sort_by { |row| -counted[row[:id]] }.first(3).select { |row| counted[row[:id]].positive? }.map { |row| row[:name] } if reasons.empty?
        estimates = []
        estimates << ESTIMATED_PAY if basis == "estimated_after_balance"
        estimates << ESTIMATED_BILLS if due.any? { |bill| bill[:estimate] }
        estimates << DEBT_MAY_BE_PAID if midmonth && debt_cents.positive?
        { label: month_start.strftime("%B"), starts_on: month_start.iso8601, from_on: midmonth&.iso8601,
          opening_cents: opening_cents, income_cents: income, income_basis: basis, approved_so_far_cents: approved,
          outflow_cents: known ? out : nil, spending_plan_known: rows.any? && allocations_known, ending_cents: cash, bills: due, reasons: reasons,
          includes_estimates: estimates.any?, estimate_reasons: estimates }
      end
      mark_spikes(months)
      short = months.find { |month| month[:ending_cents]&.negative? }
      missing = []
      missing << "your income plan" if months.any? { |month| month[:income_cents].nil? }
      missing << "a planned amount for every category" unless months.all? { |month| month[:spending_plan_known] }
      missing << "your monthly debt payments" unless debts.minimum_payment_known?
      # Every estimate behind the answer: the months up to the first short one, or all of them.
      through = short ? months[0..months.index(short)] : months
      { starting_cash_cents: starting, starting_on: anchor&.iso8601, starting_note: starting_note, months: months, first_short_month: short,
        status: short ? "short" : (months.any? && months.all? { |month| !month[:ending_cents].nil? } ? "no_short_month" : "unknown"),
        estimate_reasons: through.flat_map { |month| month[:estimate_reasons] }.uniq,
        missing: missing, bills: bills.map { |bill| present_bill(bill) },
        debt_bills: debt_bills(debts) }
    end

    private

    def opening(first)
      accounts = AssetPortfolio.new(@household).liquid_accounts
      return [ nil, nil, "Add your checking and savings balances in My Money to see ending cash." ] if accounts.empty?
      unless accounts.all? { |account| account.balance_known? && account.balance_as_of_on }
        return [ nil, nil, "Some cash balances or their dates are not saved yet. Add them in My Money to see ending cash." ]
      end
      dates = accounts.map(&:balance_as_of_on).uniq.sort
      if dates.length > 1
        return [ nil, nil, "Your cash balances have different dates (#{dates.map { |date| long(date) }.to_sentence}). Update them on the same day in My Money to see ending cash." ]
      end
      anchor = dates.first
      unless anchor <= @today && (anchor.beginning_of_month == first || anchor == first - 1)
        return [ nil, nil, "Your cash balances are from #{long(anchor)}. Update them in My Money to see ending cash." ]
      end
      [ anchor, accounts.sum(&:balance_cents), "Starting from your cash balances on #{long(anchor)}." ]
    end

    def long(date) = date.year == @today.year ? date.strftime("%B %-d") : date.strftime("%B %-d, %Y")

    def due_bills(bills, from, to, first_month)
      bills.flat_map do |bill|
        if bill.awaiting_answer?(@today)
          first_month ? [ present_bill(bill).merge(due_on: bill.due_on.iso8601, was_this_paid: true) ] : []
        else
          bill.due_dates(from, to).map { |date| present_bill(bill).merge(due_on: date.iso8601, was_this_paid: false) }
        end
      end
    end

    # Planned income for the month; in the current month approved income counts when it is more than the plan,
    # since what came in so far is not the whole month. From a midmonth balance, only income still expected.
    def income_for(period, month_end, midmonth, current)
      planned = @income[period.id].nil? ? nil : Money.cents(@income[period.id])
      return [ nil, "planned", nil ] if planned.nil?
      if midmonth
        received = actual_income_reader.received_through(midmonth)
        return [ [ planned - received, 0 ].max, "after_balance", received ] if received
        recurring = @sources.sum { |source| IncomeTimeline.recurring_monthly_cents(source, on: month_end) }
        one_time = @sources.sum { |source| IncomeTimeline.period_cents(source, starts_on: midmonth + 1, ends_on: month_end) } - recurring
        days_left = (month_end - midmonth).to_i
        return [ [ one_time, 0 ].max + recurring * days_left / month_end.day, "estimated_after_balance", nil ]
      end
      actual = current ? @actual[period.starts_on.month] : nil
      approved = actual && actual[:actual_cents]
      return [ planned, "planned", nil ] if approved.nil?
      return [ approved, "approved", approved ] unless actual[:partial] || actual[:month_open]
      approved > planned ? [ approved, "approved_so_far", approved ] : [ planned, "planned", approved ]
    end

    # How much of each sinking category's monthly plan her saved bills cover: a twelfth of what they cost over the
    # 12 months from the forecast's first month, counting a past bill still waiting for her answer.
    def covered_monthly(open_bills, rows, first)
      ids = rows.select { |row| SINKING.include?(row[:stack_key]) }.to_set { |row| row[:id] }
      window_end = first.advance(months: 12) - 1
      open_bills.select { |bill| ids.include?(bill.budget_category_id) }.group_by(&:budget_category_id).transform_values do |list|
        total = list.sum { |bill| bill.awaiting_answer?(@today) ? bill.amount_cents : bill.due_dates(first, window_end).length * bill.amount_cents }
        (total / 12.0).round
      end
    end

    def actual_income_reader = @actual_income_reader ||= ActualIncome.new(@household, today: @today)

    # Spending dated after the balance, counted the way Budget counts it, so the balance never pays for it twice.
    def spending_after(from, to)
      sums = TransactionSplit.joins(:budget_category, :household_transaction)
        .where(budget_categories: { household_id: @household.id, financial_generation: @household.financial_generation })
        .where(household_transactions: { occurred_on: from..to, status: %w[confirmed reconciled] })
        .group(:budget_category_id).sum(:amount_cents)
      RefundCredits.new(@household, from: from, to: to).category_cents.each { |id, cents| sums[id] = sums.fetch(id, 0) - cents }
      CashDrawdowns.new(@household).category_cents(from: from, to: to).each { |id, cents| sums[id] = sums.fetch(id, 0) + cents }
      sums
    end

    # A month whose costs are well above her usual month, as the year outlook marked them.
    def mark_spikes(months)
      values = months.filter_map { |month| month[:outflow_cents] unless month[:from_on] }.sort
      return months.each { |month| month[:higher_costs] = false } if values.length < 2
      typical = values[values.length / 2]
      months.each { |month| month[:higher_costs] = !month[:from_on] && month[:outflow_cents].to_i >= typical + [ SPIKE_MINIMUM_CENTS, typical / 10 ].max }
    end

    def debt_bills(debts)
      if debts.mode == "summary"
        return [] unless @household.household_profile&.debt_summary_minimum_payment_known?
        return [ { name: "Monthly debt payments", amount_cents: debts.monthly_minimum_cents } ]
      end
      @household.debts.active.current_picture.map { |debt| { name: debt.label, amount_cents: debt.minimum_payment_known? ? debt.minimum_payment_cents : nil } }
    end

    def debt_match(bill)
      @debt_list ||= debt_bills(DebtPortfolio.new(@household))
      words = ->(text) { text.to_s.downcase.scan(/[a-z0-9]+/).select { |word| word.length >= 3 } - DEBT_WORD_STOPLIST }
      @debt_list.find { |debt| (debt[:amount_cents].to_i.positive? && debt[:amount_cents] == bill.amount_cents) || words.(debt[:name]).intersect?(words.(bill.name)) }&.fetch(:name)
    end

    def present_bill(bill)
      { id: bill.id, name: bill.name, amount_cents: bill.amount_cents, due_on: bill.due_on.iso8601,
        repeat_months: bill.repeat_months, budget_category_id: bill.budget_category_id, must_pay: bill.must_pay, estimate: bill.estimate,
        paid_on: bill.paid_on&.iso8601, was_this_paid: bill.awaiting_answer?(@today), looks_like_debt: debt_match(bill) }
    end
  end
end
