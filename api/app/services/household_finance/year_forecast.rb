module HouseholdFinance
  # Whole-month cash requires opening balances, not a midmonth balance with the same income added again.
  class YearForecast
    def initialize(household, year:, periods:, rows:, monthly_income:, actual_income:, today: Date.current)
      @household, @year, @periods, @rows, @income, @actual, @today = household, year, periods, rows, monthly_income, actual_income, today
    end

    def call
      assets = AssetPortfolio.new(@household)
      cash = assets.liquid_assets_known? ? assets.liquid_assets_cents : nil
      first = [ Date.new(@year, 1, 1), @today.beginning_of_month ].max
      timing_known = assets.liquid_accounts.all? { |account| account.balance_as_of_on == first - 1 }
      cash = nil unless timing_known
      starting = cash
      debts = DebtPortfolio.new(@household)
      bills = @household.bills.current_picture.order(:due_on, :id).to_a
      months = @periods.filter_map do |period|
        next if period.starts_on < [ Date.new(@year, 1, 1), @today.beginning_of_month ].max
        index = period.starts_on.month - 1
        due = bills.filter_map do |bill|
          date = bill.due_in(period.starts_on)
          overdue = bill.repeat_months.nil? && bill.due_on < @today.beginning_of_month && period.starts_on == @today.beginning_of_month
          date = bill.due_on if overdue
          present_bill(bill).merge(due_on: date.iso8601, overdue: overdue) if date
        end
        rows = @rows.select { |row| row[:active] }
        known = rows.any? && rows.all? { |row| !row[:months][index][:allocation_missing] } && debts.minimum_payment_known?
        category_cents = rows.sum do |row|
          planned = Money.cents(row[:months][index][:planned])
          scheduled = due.select { |bill| bill[:budget_category_id] == row[:id] }.sum { |bill| bill[:amount_cents] }
          [ planned, scheduled ].max
        end
        out = category_cents + due.select { |bill| !rows.any? { |row| row[:id] == bill[:budget_category_id] } }.sum { |bill| bill[:amount_cents] } + debts.monthly_minimum_cents
        actual = period.starts_on <= @today ? @actual[period.starts_on.month] : nil
        income = actual && actual[:actual_cents]
        basis = income.nil? ? "planned" : "approved actual"
        income ||= @income[period.id].nil? ? nil : Money.cents(@income[period.id])
        opening = cash
        cash = cash && income && known ? cash + income - out : nil
        reasons = due.sort_by { |bill| -bill[:amount_cents] }.map { |bill| bill[:name] }
        reasons = rows.sort_by { |row| -Money.cents(row[:months][index][:planned]) }.first(3).map { |row| row[:name] } if reasons.empty?
        { label: period.starts_on.strftime("%B"), starts_on: period.starts_on.iso8601,
          opening_cents: opening, income_cents: income, income_basis: basis, actual_partial: basis == "approved actual" && actual && actual[:partial],
          outflow_cents: known ? out : nil, ending_cents: cash, bills: due, reasons: reasons }
      end
      short = months.find { |month| month[:ending_cents]&.negative? }
      { starting_cash_cents: starting, months: months, first_short_month: short,
        status: short ? "short" : (months.any? && months.all? { |month| !month[:ending_cents].nil? } ? "no_short_month" : "unknown"),
        bills: bills.map { |bill| present_bill(bill) },
        debt_bills: @household.debts.active.current_picture.map { |debt| { name: debt.label, amount_cents: debt.minimum_payment_known? ? debt.minimum_payment_cents : nil, due_on: debt.source_metadata["due_on"], must_pay: true } },
        rule: "Whole-month forecast, not today's spendable cash. Starting cash needs every liquid account balance dated at the end of the previous month; other dates stay unknown so income and spending are never counted again against a midmonth balance. Approved income replaces the plan when known, even if partial. Category spending and sinking funds count once: the larger of the category plan or its bills. Debt minimums count once. A negative balance is the first short month; missing balances, spending or income leave the result unknown." }
    end

    private

    def present_bill(bill)
      { id: bill.id, name: bill.name, amount_cents: bill.amount_cents, due_on: bill.due_on.iso8601,
        repeat_months: bill.repeat_months, budget_category_id: bill.budget_category_id, must_pay: bill.must_pay, estimate: bill.estimate }
    end
  end
end
