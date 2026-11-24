module HouseholdFinance
  # Cash at the end of each month through December. Every rule keeps a cost or income from counting twice:
  # - Opening cash is her checking, savings and cash balances, all known and all dated the same day: in the current
  #   month or the last day of the month before. Other dates leave cash unknown rather than guess what already happened.
  #   A balance dated a month's last day already includes that whole month, so the forecast starts with the next one.
  # - From a midmonth balance only what comes after that day counts for the rest of the month: income still expected,
  #   bills due after it, and what is left of each category's plan. A debt tracked one by one with a saved due day counts
  #   on that day (days 29 to 31 fall on a short month's last day), so from a midmonth balance only a payment due after
  #   it counts. A minimum with no due day, or the one-total summary, still counts in full, and the month says it may
  #   already be paid.
  # - Past-due amounts on debts and on bills are owed now: each counts once, in the first forecast month, on top of
  #   that month's scheduled payments. A debt's catch-up is part of its balance, so it never counts above the balance,
  #   and its later minimums stop once the balance is paid. A bill's past-due amount is never part of the monthly plan
  #   its saved bills cover; in its category it adds to the plan or the bill, and spending recorded this month counts
  #   toward the two together, so a catch-up already paid this month is not counted twice.
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
    PAST_DUE = "past due".freeze

    def call
      first = [ Date.new(@year, 1, 1), @today.beginning_of_month ].max
      anchor, cash, starting_note = opening(first)
      # Dated the month's last day, the balance already holds that whole month: nothing of it is left to count.
      first = first.next_month if anchor && anchor == first.end_of_month && @periods.any? { |period| period.starts_on == first.next_month }
      starting = cash
      debts = DebtPortfolio.new(@household)
      bills = @household.bills.current_picture.order(:due_on, :id).to_a
      open_bills = bills.reject(&:paid_on)
      # The plan lists an archived category only when it has spending: that spending still counts, but none of its plan.
      rows = @rows
      active_rows = rows.select { |row| row[:active] }
      covered = covered_monthly(open_bills, active_rows, first)
      plan_known = active_rows.any? && debts.minimum_payment_known?
      debt_schedule = YearForecastDebtSchedule.new(@household, debts, @today)
      months = @periods.select { |period| period.starts_on >= first }.sort_by(&:starts_on).map do |period|
        month_start, month_end = period.starts_on, period.starts_on.end_of_month
        index = month_start.month - 1
        current = month_start == @today.beginning_of_month
        midmonth = anchor if anchor && anchor.beginning_of_month == month_start
        closed = midmonth == month_end
        from = midmonth ? midmonth + 1 : month_start
        first_month = month_start == first
        due = due_bills(open_bills, from, month_end, first_month)
        spent_after = midmonth ? spending_after(midmonth + 1, month_end) : {}
        # Sinking bills dated on or before a midmonth balance were paid from cash already counted; spending up to their
        # amount was those covered bills, not the part of the plan they don't cover. An overdue one-time bill still
        # awaiting a paid answer is unpaid and still counts in upcoming outflow, so it must not offset earlier spending.
        paid_before = midmonth ? bills_due_by_category(bills.reject { |bill| bill.awaiting_answer?(@today) }, month_start, midmonth) : {}
        counted = rows.to_h do |row|
          cell = row[:months][index]
          planned = row[:active] ? Money.cents(cell[:planned]) : 0
          in_row = due.select { |bill| bill[:budget_category_id] == row[:id] }
          linked = in_row.reject { |bill| bill[:past_due] }.sum { |bill| bill[:amount_cents] }
          # Owed from before: on top of this month's plan or bill, never inside the plan its bills cover.
          arrears = in_row.select { |bill| bill[:past_due] }.sum { |bill| bill[:amount_cents] }
          spent = current ? Money.cents(cell[:actual]) : 0
          after = spent_after.fetch(row[:id], 0)
          # Sinking groups: only the part of the plan her saved bills don't cover leaves, plus the bills when due.
          plan = SINKING.include?(row[:stack_key]) ? [ planned - covered.fetch(row[:id], 0), 0 ].max : planned
          due_extra = SINKING.include?(row[:stack_key]) ? linked : 0
          cents = if closed
            linked + arrears
          elsif midmonth
            before = spent - after
            before = [ before - paid_before.fetch(row[:id], 0), 0 ].max if SINKING.include?(row[:stack_key])
            # Spending before the balance counts toward the plan and the catch-up together: what went past the plan
            # paid part of the catch-up, so only the rest of it is still owed.
            arrears_left = [ arrears - [ before - plan, 0 ].max, 0 ].max
            [ [ plan - before, 0 ].max + due_extra + arrears_left, linked + arrears_left, after ].max
          else
            [ plan + due_extra + arrears, linked + arrears, spent ].max
          end
          [ row[:id], cents ]
        end
        allocations_known = active_rows.all? { |row| !row[:months][index][:allocation_missing] }
        known = plan_known && allocations_known
        outside = due.reject { |bill| counted.key?(bill[:budget_category_id]) }
        # A closed month (balance dated its last day) has nothing scheduled left; what is owed now still counts.
        debt_items = debt_schedule.items(month_start, month_end, from, first_month: first_month, past_due_only: closed)
        debt_cents = debt_items.sum { |item| item[:amount_cents] }
        out = counted.values.sum + outside.sum { |bill| bill[:amount_cents] } + debt_cents
        income, basis, approved = closed ? [ 0, "after_balance", nil ] : income_for(period, month_end, midmonth, current)
        opening_cents = cash
        cash = cash && income && known ? cash + income - out : nil
        owed_now = (due.select { |bill| bill[:past_due] } + debt_items.select { |item| item[:past_due] })
        reasons = owed_now.sort_by { |item| -item[:amount_cents] }.map { |item| "#{item[:name]} (#{PAST_DUE})" } +
          due.reject { |bill| bill[:past_due] }.sort_by { |bill| -bill[:amount_cents] }.map { |bill| bill[:name] }
        reasons = reasons.uniq
        reasons = rows.sort_by { |row| -counted[row[:id]] }.first(3).select { |row| counted[row[:id]].positive? }.map { |row| row[:name] } if reasons.empty?
        estimates = []
        estimates << ESTIMATED_PAY if basis == "estimated_after_balance"
        estimates << ESTIMATED_BILLS if due.any? { |bill| bill[:estimate] }
        # Only a payment with no saved due day may already be paid: a dated one before the balance is left out.
        estimates << DEBT_MAY_BE_PAID if midmonth && debt_items.any? { |item| item[:undated] && item[:amount_cents].positive? }
        { label: month_start.strftime("%B"), starts_on: month_start.iso8601, from_on: midmonth&.iso8601,
          opening_cents: opening_cents, income_cents: income, income_basis: basis, approved_so_far_cents: approved,
          outflow_cents: known ? out : nil, spending_plan_known: active_rows.any? && allocations_known, ending_cents: cash, bills: due, debts: debt_items, reasons: reasons,
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

    def bills_due_by_category(bills, from, to)
      bills.each_with_object(Hash.new(0)) do |bill, totals|
        totals[bill.budget_category_id] += bill.amount_cents * bill.due_dates(from, to).length if bill.budget_category_id
      end
    end

    # first_month: the forecast's first month, where a one-time bill past its date and each bill's past-due amount
    # (owed now, once) count.
    def due_bills(bills, from, to, first_month)
      bills.flat_map do |bill|
        scheduled = if bill.awaiting_answer?(@today)
          first_month ? [ present_bill(bill).merge(due_on: bill.due_on.iso8601, was_this_paid: true) ] : []
        else
          bill.due_dates(from, to).map { |date| present_bill(bill).merge(due_on: date.iso8601, was_this_paid: false) }
        end
        next scheduled unless first_month && bill.past_due_owed?(@today)

        owed_on = [ [ from, @today ].max, to ].min
        scheduled + [ present_bill(bill).merge(amount_cents: bill.past_due_cents, due_on: owed_on.iso8601, was_this_paid: false, past_due: true, estimate: false) ]
      end
    end

    # Planned income for the month; in the current month approved income counts when it is more than the plan,
    # since what came in so far is not the whole month. From a midmonth balance, only income still expected.
    def income_for(period, month_end, midmonth, current)
      planned = @income[period.id].nil? ? nil : Money.cents(@income[period.id])
      return [ nil, "planned", nil ] if planned.nil?
      actual = current ? @actual[period.starts_on.month] : nil
      approved = actual && actual[:actual_cents]
      if midmonth
        received = actual_income_reader.received_through(midmonth)
        # Approved income above the plan, some of it after the balance date, still comes in.
        return [ [ [ planned, approved.to_i ].max - received, 0 ].max, "after_balance", received ] if received
        recurring = @sources.sum { |source| IncomeTimeline.recurring_monthly_cents(source, on: month_end) }
        one_time = @sources.sum { |source| IncomeTimeline.period_cents(source, starts_on: midmonth + 1, ends_on: month_end) } - recurring
        days_left = (month_end - midmonth).to_i
        return [ [ one_time, 0 ].max + recurring * days_left / month_end.day, "estimated_after_balance", nil ]
      end
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
      middle = values.length / 2
      typical = values.length.even? ? (values[middle - 1] + values[middle]) / 2 : values[middle]
      months.each { |month| month[:higher_costs] = !month[:from_on] && month[:outflow_cents].to_i >= typical + [ SPIKE_MINIMUM_CENTS, typical / 10 ].max }
    end

    # Each debt payment the forecast counts, from My Money: its minimum, saved due day and anything past due.
    def debt_bills(debts)
      arrears = @household.debts.active.current_picture.select(&:past_due?).map do |debt|
        { name: debt.label, amount_cents: nil, due_day: debt.due_day, past_due_cents: debt.past_due_cents }
      end
      if debts.mode == "summary"
        return arrears unless @household.household_profile&.debt_summary_minimum_payment_known?
        return [ { name: "Monthly debt payments", amount_cents: debts.monthly_minimum_cents, due_day: nil, past_due_cents: nil } ] + arrears
      end
      @household.debts.active.current_picture.map do |debt|
        { name: debt.label, amount_cents: debt.minimum_payment_known? ? debt.minimum_payment_cents : nil, due_day: debt.due_day, past_due_cents: debt.past_due? ? debt.past_due_cents : nil }
      end
    end

    def debt_match(bill)
      @debt_list ||= debt_bills(DebtPortfolio.new(@household))
      words = ->(text) { text.to_s.downcase.scan(/[a-z0-9]+/).select { |word| word.length >= 3 } - DEBT_WORD_STOPLIST }
      @debt_list.find { |debt| (debt[:amount_cents].to_i.positive? && debt[:amount_cents] == bill.amount_cents) || words.(debt[:name]).intersect?(words.(bill.name)) }&.fetch(:name)
    end

    def present_bill(bill)
      { id: bill.id, name: bill.name, amount_cents: bill.amount_cents, due_on: bill.due_on.iso8601,
        repeat_months: bill.repeat_months, budget_category_id: bill.budget_category_id, must_pay: bill.must_pay, estimate: bill.estimate,
        paid_on: bill.paid_on&.iso8601, was_this_paid: bill.awaiting_answer?(@today), looks_like_debt: debt_match(bill),
        past_due_cents: bill.past_due_cents, past_due: false }
    end
  end
end
