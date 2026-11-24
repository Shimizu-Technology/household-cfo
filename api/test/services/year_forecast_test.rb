require "test_helper"

class YearForecastTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "talun-forecast@example.invalid", clerk_id: "talun-forecast")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    @household.accounts.create!(label: "Talun cash", account_type: "checking", balance_cents: 100_000, balance_known: true, balance_as_of_on: "2025-12-31")
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_minimum_payment_known: true, debt_summary_minimum_payment_cents: 0)
    category = @household.budget_categories.create!(name: "Utilities", stack_key: "non_discretionary")
    @periods = (1..12).map { |month| Struct.new(:id, :starts_on).new(month, Date.new(2026, month, 1)) }
    @rows = [ row(category, 100) ]
    @household.bills.create!(name: "Power", amount_cents: 8000, due_on: "2026-01-31", repeat_months: 1, budget_category: category)
  end

  test "rolling cash includes category bills once and finds the one time shortfall reason" do
    @household.bills.create!(name: "Car registration", amount_cents: 150_000, due_on: "2026-03-10")
    result = forecast
    assert_equal [ 110_000, 120_000, -20_000 ], result[:months].first(3).map { |month| month[:ending_cents] }
    assert_equal "March", result[:first_short_month][:label]
    assert_includes result[:first_short_month][:reasons], "Car registration"
    assert_equal "2026-02-28", result[:months][1][:bills][0][:due_on]
    assert_equal "Starting from your cash balances on December 31, 2025.", result[:starting_note]
  end

  test "a bill above its category plan counts the bill, not both" do
    @household.bills.first.update!(amount_cents: 15_000)
    assert_equal 15_000, forecast[:months][0][:outflow_cents]
  end

  # $1,500 yearly registration, $125 a month set aside, due in March: the registration costs $1,500 once, not $125 x 11 + $1,500.
  test "a planned yearly cost with a saved bill counts the bill when due, not the monthly set aside as well" do
    sinking = @household.budget_categories.create!(name: "Car registration", stack_key: "sinking_expected")
    @rows << row(sinking, 125)
    @household.bills.create!(name: "Car registration", amount_cents: 150_000, due_on: "2026-03-10", repeat_months: 12, budget_category: sinking)
    result = forecast
    assert_equal [ 110_000, 120_000, -20_000, -10_000 ], result[:months].first(4).map { |month| month[:ending_cents] }
    assert_equal 12 * 10_000 + 150_000, result[:months].sum { |month| month[:outflow_cents] }
    assert_equal "March", result[:first_short_month][:label]
    assert result[:months][2][:higher_costs]
    assert_not result[:months][1][:higher_costs]

    @household.bills.find_by!(name: "Car registration").destroy!
    assert_equal 22_500, forecast[:months][0][:outflow_cents], "with no saved bill the set aside still counts, so the cost is not lost"
  end

  # Car plan $250 a month: registration $125 + insurance $75 + repairs $50. Only the $1,500 yearly registration is saved,
  # so $1,500 / 12 = $125 of the plan is covered and the other $125 a month still leaves.
  test "a sinking category counts the part of its plan its saved bills don't cover" do
    car = @household.budget_categories.create!(name: "Car", stack_key: "sinking_expected")
    @rows << row(car, 250)
    @household.bills.create!(name: "Car registration", amount_cents: 150_000, due_on: "2026-03-10", repeat_months: 12, budget_category: car)
    result = forecast
    # January: $1,000 + $200 - ($100 utilities + $125 uncovered car) = $975; February $950; March adds the $1,500 bill: -$575.
    assert_equal [ 97_500, 95_000, -57_500 ], result[:months].first(3).map { |month| month[:ending_cents] }
    assert_equal [ 22_500, 22_500, 172_500 ], result[:months].first(3).map { |month| month[:outflow_cents] }
    assert_equal 12 * 22_500 + 150_000, result[:months].sum { |month| month[:outflow_cents] }
  end

  # Surprise fund $100 a month; one saved $690 repair in September covers $690 / 12 = $57.50 a month. The other $42.50
  # still counts every month, before and after the repair, so future surprises aren't erased.
  test "one saved surprise repair covers only its share of the surprise fund" do
    surprises = @household.budget_categories.create!(name: "Surprises", stack_key: "sinking_unexpected")
    @rows << row(surprises, 100)
    @household.bills.create!(name: "Talun repair", amount_cents: 69_000, due_on: "2026-09-22", budget_category: surprises)
    months = forecast[:months]
    assert_equal 14_250, months[0][:outflow_cents]
    assert_equal 105_750, months[0][:ending_cents]
    assert_equal 10_000 + 4_250 + 69_000, months[8][:outflow_cents]
    assert_equal 14_250, months[9][:outflow_cents]
    # $1,000 + 12 x $200 - 12 x $142.50 - $690 = $1,000.
    assert_equal 100_000, months[11][:ending_cents]
  end

  # A balance dated November 30 already holds all of November: no income, bills, plan or debt payment counts again.
  test "a balance dated the month's last day starts the forecast with the next month" do
    @household.household_profile.update!(debt_summary_minimum_payment_cents: 4_500)
    @household.income_sources.create!(label: "Talun pay", amount_cents: 20_000, cadence: "monthly", source_type: "job")
    @household.accounts.first.update!(balance_as_of_on: "2026-11-30")
    @household.bills.create!(name: "Talun fee", amount_cents: 2_000, due_on: "2026-11-05")
    result = forecast(today: Date.new(2026, 11, 30))
    december = result[:months].sole
    assert_equal "December", december[:label]
    assert_nil december[:from_on]
    assert_equal 100_000, december[:opening_cents]
    # December: $1,000 + $200 - ($100 utilities + $45 debt + $20 fee still waiting for her answer) = $1,035.
    assert_equal 16_500, december[:outflow_cents]
    assert_equal 103_500, december[:ending_cents]
    assert december[:bills].find { |bill| bill[:name] == "Talun fee" }[:was_this_paid]
    assert_empty result[:estimate_reasons]
    assert_equal "Starting from your cash balances on November 30.", result[:starting_note]

    @household.accounts.first.update!(balance_as_of_on: "2026-12-31")
    december = forecast(today: Date.new(2026, 12, 31))[:months].sole
    assert_equal [ 0, 2_000, 98_000 ], december.values_at(:income_cents, :outflow_cents, :ending_cents), "the last day of the year: only the unanswered fee is left"
  end

  test "unknown cash stays unknown" do
    @household.accounts.first.update!(balance_known: false, balance_cents: 0, balance_as_of_on: nil)
    assert_nil forecast[:starting_cash_cents]
    assert_equal "unknown", forecast[:status]
    assert forecast[:months].all? { |month| month[:ending_cents].nil? }
    assert_match(/not saved yet/, forecast[:starting_note])
  end

  test "balances from different days or an earlier month stay unknown" do
    @household.accounts.create!(label: "Talun savings", account_type: "savings", balance_cents: 5_000, balance_known: true, balance_as_of_on: "2026-01-10")
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    result = forecast(today: Date.new(2026, 1, 20))
    assert_nil result[:starting_cash_cents]
    assert_equal "Your cash balances have different dates (January 10 and January 15). Update them on the same day in My Money to see ending cash.", result[:starting_note]

    @household.accounts.update_all(balance_as_of_on: "2025-12-15")
    result = forecast(today: Date.new(2026, 1, 20))
    assert_nil result[:starting_cash_cents]
    assert_equal "unknown", result[:status]
    assert_equal "Your cash balances are from December 15, 2025. Update them in My Money to see ending cash.", result[:starting_note]
  end

  test "a midmonth balance counts only income, bills and plan left after that day" do
    @household.income_sources.create!(label: "Talun pay", amount_cents: 20_000, cadence: "monthly", source_type: "job")
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    @rows[0][:months][0][:actual] = 30
    result = forecast(today: Date.new(2026, 1, 20))
    january = result[:months][0]
    assert_equal "2026-01-15", january[:from_on]
    assert_equal 100_000, january[:opening_cents]
    # No approved statements: $200 x 16 of 31 days is an estimate. Utilities: $100 plan - $30 spent = $70 left, but the $80 power bill is due after the 15th.
    assert_equal 10_322, january[:income_cents]
    assert_equal "estimated_after_balance", january[:income_basis]
    assert january[:includes_estimates]
    assert_equal 8_000, january[:outflow_cents]
    assert_equal 102_322, january[:ending_cents]
    assert_equal 112_322, result[:months][1][:ending_cents]
    assert_equal "Starting from your cash balances on January 15.", result[:starting_note]
  end

  # Debt due dates aren't saved, so a midmonth month still counts the $45 minimum but says it may already be paid.
  test "a midmonth balance counts debt minimums in full and says they may already be paid" do
    @household.household_profile.update!(debt_summary_minimum_payment_cents: 4_500)
    @household.income_sources.create!(label: "Talun pay", amount_cents: 20_000, cadence: "monthly", source_type: "job")
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    @household.bills.first.update!(estimate: true)
    @rows[0][:months][0][:actual] = 30
    result = forecast(today: Date.new(2026, 1, 20))
    january, february = result[:months]
    # $1,000 + $103.22 estimated pay - ($80 power, above the $70 of plan left, + $45 debt) = $978.22.
    assert_equal 12_500, january[:outflow_cents]
    assert_equal 97_822, january[:ending_cents]
    assert_equal [ "estimated pay for the rest of this month", "estimated bill amounts", "debt payments that may already be paid this month" ], january[:estimate_reasons]
    assert january[:includes_estimates]
    assert_equal [ "estimated bill amounts" ], february[:estimate_reasons]
    assert_equal "no_short_month", result[:status]
    assert_equal january[:estimate_reasons], result[:estimate_reasons]
    # February to December each add $200 - $100 - $45 = $55: $978.22 + 11 x $55 = $1,583.22.
    assert_equal 158_322, result[:months].last[:ending_cents]
    answer = HouseholdFinance::YearForecastAnswer.new(@household, "Will we make it through the year?", forecast: result, today: Date.new(2026, 1, 20)).call
    assert_equal "No month runs short through December in this plan; December would end with about $1,583.22. This rests on estimates: estimated pay for the rest of this month, estimated bill amounts, and debt payments that may already be paid this month. Starting from your cash balances on January 15.", answer
  end

  test "a midmonth balance with statements through that day counts only the plan's income still to come" do
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    service = HouseholdFinance::YearForecast.new(@household, year: 2026, periods: @periods, rows: @rows,
      monthly_income: (1..12).to_h { |month| [ month, 200 ] }, actual_income: {}, today: Date.new(2026, 1, 20))
    received = Object.new
    def received.received_through(date) = (date == Date.new(2026, 1, 15) ? 15_000 : raise("wrong date"))
    service.instance_variable_set(:@actual_income_reader, received)
    january = service.call[:months][0]
    # $200 planned, $150 already approved by the 15th and so already in the balance: $50 still to come.
    assert_equal 5_000, january[:income_cents]
    assert_equal "after_balance", january[:income_basis]
    assert_not january[:includes_estimates]
  end

  test "a midmonth balance never pays again for spending recorded before it" do
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    @rows[0][:months][0][:actual] = 90
    result = forecast(today: Date.new(2026, 1, 20))
    # $90 already spent before the 15th: $10 of plan is left, below the $80 power bill still due.
    assert_equal 8_000, result[:months][0][:outflow_cents]
    @household.bills.first.update!(due_on: "2026-01-10")
    assert_equal 1_000, forecast(today: Date.new(2026, 1, 20))[:months][0][:outflow_cents]
  end

  test "a covered sinking bill paid before a midmonth balance keeps the uncovered plan in that month" do
    car = @household.budget_categories.create!(name: "Car", stack_key: "sinking_expected")
    @rows << row(car, 250)
    @household.bills.create!(name: "Car registration", amount_cents: 150_000, due_on: "2026-03-10", repeat_months: 12, budget_category: car)
    @household.accounts.first.update!(balance_as_of_on: "2026-03-15")
    @rows[1][:months][2][:actual] = 1_500
    march = forecast(today: Date.new(2026, 3, 20))[:months][0]
    assert_equal "2026-03-15", march[:from_on]
    # $1,500 paid on the 10th was the covered bill, not the $125 a month the bill doesn't cover: $100 utilities + $125 car.
    assert_equal 22_500, march[:outflow_cents]
    # Spending beyond the bill still uses up the uncovered plan: $1,550 spent leaves $75 of the $125.
    @rows[1][:months][2][:actual] = 1_550
    assert_equal 17_500, forecast(today: Date.new(2026, 3, 20))[:months][0][:outflow_cents]
  end

  test "partial current month income uses the larger of approved so far and the plan" do
    result = forecast(actual: { 1 => { actual_cents: 5000, partial: true, month_open: true } })
    assert_equal 20_000, result[:months][0][:income_cents]
    assert_equal "planned", result[:months][0][:income_basis]
    assert_equal 5000, result[:months][0][:approved_so_far_cents]
    assert_equal 110_000, result[:months][0][:ending_cents]

    result = forecast(actual: { 1 => { actual_cents: 30_000, partial: true, month_open: true } })
    assert_equal 30_000, result[:months][0][:income_cents]
    assert_equal "approved_so_far", result[:months][0][:income_basis]
  end

  test "spending already above the plan this month counts what was spent" do
    @rows[0][:months][0][:actual] = 150
    result = forecast
    assert_equal 15_000, result[:months][0][:outflow_cents]
    assert_equal 10_000, result[:months][1][:outflow_cents]
  end

  test "a past one time bill counts once until she marks it paid" do
    repair = @household.bills.create!(name: "Talun repair", amount_cents: 30_000, due_on: "2025-12-20")
    result = forecast
    assert_equal [ "Talun repair", "Power" ], result[:months][0][:bills].map { |bill| bill[:name] }
    assert result[:months][0][:bills].first[:was_this_paid]
    assert_equal 40_000, result[:months][0][:outflow_cents]
    assert_equal [ "Power" ], result[:months][1][:bills].map { |bill| bill[:name] }
    assert result[:bills].find { |bill| bill[:name] == "Talun repair" }[:was_this_paid]

    repair.update!(paid_on: "2026-01-01")
    result = forecast
    assert_equal 10_000, result[:months][0][:outflow_cents]
    assert result[:months].none? { |month| month[:bills].any? { |bill| bill[:name] == "Talun repair" } }
    @household.bills.create!(name: "Talun fee", amount_cents: 2_000, due_on: "2026-04-10", paid_on: "2026-01-01")
    april = forecast[:months][3]
    assert april[:bills].none? { |bill| bill[:name] == "Talun fee" }
    assert_equal 10_000, april[:outflow_cents]
  end

  test "a bill that matches a debt minimum is flagged" do
    @household.household_profile.update!(debt_summary_minimum_payment_cents: 4_500)
    @household.bills.create!(name: "Talun card", amount_cents: 4_500, due_on: "2026-02-05", repeat_months: 1)
    bill = forecast[:bills].find { |item| item[:name] == "Talun card" }
    assert_equal "Monthly debt payments", bill[:looks_like_debt]
    assert_nil forecast[:bills].find { |item| item[:name] == "Power" }[:looks_like_debt]
  end

  test "recurrence is anchored and clamps short months" do
    bill = @household.bills.first
    bill.repeat_months = 3
    assert_nil bill.due_in(Date.new(2026, 2, 1))
    assert_equal Date.new(2026, 4, 30), bill.due_in(Date.new(2026, 4, 1))
    bill.repeat_months = 12
    assert_equal Date.new(2027, 1, 31), bill.due_in(Date.new(2027, 1, 1))
    bill.repeat_months = nil
    assert_nil bill.due_in(Date.new(2027, 1, 1))
    assert_raises(ActiveRecord::RecordInvalid) { @household.bills.first.update!(paid_on: "2026-01-01") }
  end

  test "Talun manifest arrears and one off repair remain dated costs with hand checked cash" do
    events = JSON.parse(Rails.root.join("test/fixtures/files/documents/talun-year/manifest.json").read).fetch("events")
    %w[talun-2026-05-power-arrears talun-2026-09-one-off-repair].each do |id|
      event = events.find { |item| item.fetch("event_id") == id }
      @household.bills.create!(name: event.fetch("merchant"), amount_cents: -event.fetch("signed_amount_cents"), due_on: event.fetch("date"))
    end
    @household.accounts.first.update!(balance_cents: 10_000)
    result = forecast(income: 180)
    assert_equal 31_355, result[:months][4][:ending_cents]
    assert_equal(-5645, result[:months][8][:ending_cents])
    assert_equal "September", result[:first_short_month][:label]
    assert_includes result[:first_short_month][:reasons], "Tasi Demo Appliance Repair"
  end

  # A January 20 purchase in a category archived on January 21 is not in the January 15 balance, so it still leaves cash.
  test "spending after the balance in an archived category still counts, without its plan" do
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    archived = @household.budget_categories.create!(name: "Talun hobby", stack_key: "discretionary")
    period = HouseholdFinance::AnnualBudgetManager.new(@household).current_period_for(Date.new(2026, 1, 20))
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: Date.new(2026, 1, 20), status: "confirmed",
      merchant: "Talun hobby shop", total_amount_cents: 4_000, source_type: "manual_ui")
    transaction.transaction_splits.create!(budget_category: archived, amount_cents: 4_000)
    archived.update!(active: false)
    @rows << row(archived, 500).merge(active: false).tap { |archived_row| archived_row[:months][0][:actual] = 40 }
    result = forecast(today: Date.new(2026, 1, 25))
    # Utilities' $100 plan (above the $80 power bill), plus the $40 spent in the archived category after the balance.
    assert_equal 14_000, result[:months][0][:outflow_cents]
    # Its $500 plan never comes back in later months.
    assert_equal 10_000, result[:months][1][:outflow_cents]
  end

  test "a midmonth balance keeps approved income above the plan that came in after it" do
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    january = ->(approved) do
      service = HouseholdFinance::YearForecast.new(@household, year: 2026, periods: @periods, rows: @rows,
        monthly_income: (1..12).to_h { |month| [ month, 200 ] }, actual_income: { 1 => { actual_cents: approved, partial: true, month_open: true } }, today: Date.new(2026, 1, 20))
      received = Object.new
      def received.received_through(_date) = 15_000
      service.instance_variable_set(:@actual_income_reader, received)
      service.call[:months][0]
    end
    # $300 approved through the 20th, $150 of it by the 15th: the $150 after the balance still comes in.
    assert_equal 15_000, january.call(30_000)[:income_cents]
    # $180 approved is below the $200 plan: the plan's $50 still to come.
    assert_equal 5_000, january.call(18_000)[:income_cents]
  end

  # November $100 and December $1,500: the median of two months is $800, so December is well above it.
  test "higher cost months compare against a true median for an even number of months" do
    @household.bills.destroy_all
    @rows = [ { id: 0, active: true, name: "Talun costs", stack_key: "non_discretionary", months: Array.new(12) { |index| { planned: index == 11 ? 1_500 : 100, actual: 0 } } } ]
    @household.accounts.first.update!(balance_as_of_on: "2026-10-31")
    months = forecast(today: Date.new(2026, 11, 1))[:months]
    assert_equal %w[November December], months.map { |month| month[:label] }
    assert months.last[:higher_costs]
    assert_not months.first[:higher_costs]
  end

  test "an unpaid overdue one-time sinking bill before a midmonth balance does not offset unrelated earlier spending" do
    @household.bills.destroy_all
    sinking = @household.budget_categories.create!(name: "Talun yearly", stack_key: "sinking_expected")
    # $250/mo plan with an unpaid one-time $1,500 bill due March 10 (still awaiting paid confirmation on March 15):
    # uncovered plan is $125/mo. Unrelated $125 spent on March 5 already used March's uncovered plan, so March outflow
    # must stay $1,500 (just the unpaid bill), not $1,625.
    @household.bills.create!(name: "Talun tax", amount_cents: 150_000, due_on: Date.new(2026, 3, 10), budget_category: sinking)
    @household.accounts.first.update!(balance_as_of_on: "2026-03-15")
    @rows = [ row(sinking, 250).tap { |sinking_row| sinking_row[:months][2][:actual] = 125 } ]
    march = forecast(today: Date.new(2026, 3, 15))[:months].find { |month| month[:label] == "March" }
    assert_equal 150_000, march[:outflow_cents]
  end

  # Talun's debts tracked one by one: the car loan is due on the 10th, the store card on the 31st, the clinic plan has
  # no saved due day.
  test "a debt with a saved due day counts on that day, so a midmonth balance leaves out one already due" do
    @household.household_profile.update!(debt_tracking_mode: "individual")
    @household.debts.create!(label: "Car loan", debt_type: "auto_loan", balance_cents: 980_000, minimum_payment_cents: 31_000, due_day: 10)
    @household.debts.create!(label: "Store card", debt_type: "credit_card", balance_cents: 64_000, minimum_payment_cents: 3_500, due_day: 31)
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    result = forecast(today: Date.new(2026, 1, 20))
    january, february = result[:months]

    # January from the 16th: the car loan (due the 10th) is in the balance; the store card is due the 31st.
    assert_equal [ [ "Store card", 3_500, "2026-01-31" ] ], january[:debts].map { |item| item.values_at(:name, :amount_cents, :due_on) }
    assert_equal 10_000 + 3_500, january[:outflow_cents]
    assert_not_includes january[:estimate_reasons], HouseholdFinance::YearForecast::DEBT_MAY_BE_PAID, "every counted payment has a date after the balance"
    # February has 28 days: the store card's 31st falls on the 28th.
    assert_equal [ [ "Car loan", "2026-02-10" ], [ "Store card", "2026-02-28" ] ], february[:debts].map { |item| item.values_at(:name, :due_on) }
    assert_equal 10_000 + 31_000 + 3_500, february[:outflow_cents]
    assert_equal [ 10, 31 ], result[:debt_bills].map { |debt| debt[:due_day] }

    @household.debts.create!(label: "Clinic plan", debt_type: "medical", balance_cents: 30_000, minimum_payment_cents: 2_500)
    january = forecast(today: Date.new(2026, 1, 20))[:months].first
    assert_includes january[:debts].map { |item| item[:name] }, "Clinic plan"
    assert_includes january[:estimate_reasons], HouseholdFinance::YearForecast::DEBT_MAY_BE_PAID, "an undated minimum may already be paid"
  end

  test "a debt's past-due amount counts once, owed now, never above its balance" do
    @household.household_profile.update!(debt_tracking_mode: "individual")
    @household.debts.create!(label: "Car loan", debt_type: "auto_loan", balance_cents: 980_000, minimum_payment_cents: 31_000, due_day: 10, past_due_cents: 150_000)
    # All of Visa's $100 balance is past due: catching up pays it off, so no minimum follows.
    @household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 10_000, minimum_payment_cents: 2_500, due_day: 5, past_due_cents: 10_000)
    months = forecast[:months]

    assert_equal [ [ "Car loan", 150_000, true ], [ "Visa", 10_000, true ], [ "Car loan", 31_000, false ] ],
      months[0][:debts].map { |item| item.values_at(:name, :amount_cents, :past_due) }
    assert_equal 10_000 + 150_000 + 10_000 + 31_000, months[0][:outflow_cents]
    assert_equal [ "Car loan (past due)", "Visa (past due)" ], months[0][:reasons].first(2)
    assert_equal [ [ "Car loan", 31_000 ] ], months[1][:debts].map { |item| item.values_at(:name, :amount_cents) }, "owed once, in the first month only"
    assert_equal 10_000 + 31_000, months[1][:outflow_cents]
    assert_equal 150_000, forecast[:debt_bills].find { |debt| debt[:name] == "Car loan" }[:past_due_cents]

    # A balance dated January 31 starts the forecast in February, which then carries the past-due amount.
    @household.accounts.first.update!(balance_as_of_on: "2026-01-31")
    february = forecast(today: Date.new(2026, 1, 31))[:months].first
    assert_equal "February", february[:label]
    assert_equal [ 150_000, 10_000 ], february[:debts].select { |item| item[:past_due] }.map { |item| item[:amount_cents] }
  end

  # Talun Telecom: $120 a month, $951.70 behind from earlier months.
  test "a recurring bill's past-due amount counts once in the first month, outside the monthly plan" do
    @household.bills.create!(name: "Talun Telecom", amount_cents: 12_000, due_on: "2026-01-12", repeat_months: 1, past_due_cents: 95_170)
    months = forecast[:months]
    assert_equal 10_000 + 12_000 + 95_170, months[0][:outflow_cents]
    assert_equal "Talun Telecom (past due)", months[0][:reasons].first
    past_due = months[0][:bills].find { |bill| bill[:past_due] }
    assert_equal [ "Talun Telecom", 95_170, "2026-01-01" ], past_due.values_at(:name, :amount_cents, :due_on)
    assert_equal 10_000 + 12_000, months[1][:outflow_cents]
    assert_empty months[1][:bills].select { |bill| bill[:past_due] }
  end

  test "a one-time bill she marked paid never counts its past-due amount" do
    @household.bills.create!(name: "Talun clinic visit", amount_cents: 18_000, due_on: "2026-01-05", paid_on: "2026-01-03", past_due_cents: 5_000)
    assert_equal 10_000, forecast[:months][0][:outflow_cents]
  end

  # Power: $80 a month in Utilities ($100 plan), $200 behind. Spending recorded this month counts toward the plan and
  # the catch-up together, so a catch-up already paid this month is not counted twice.
  test "a category bill's past-due amount adds to the plan, and this month's spending counts toward both" do
    @household.bills.first.update!(past_due_cents: 20_000)
    assert_equal 30_000, forecast[:months][0][:outflow_cents], "$100 plan + $200 past due"

    @rows[0][:months][0][:actual] = 250
    assert_equal 30_000, forecast[:months][0][:outflow_cents], "$250 spent so far is part of the $300 owed, not on top"
    @rows[0][:months][0][:actual] = 350
    assert_equal 35_000, forecast[:months][0][:outflow_cents], "spending above the plan and catch-up counts"
    assert_equal 10_000, forecast[:months][1][:outflow_cents]
  end

  private

  def row(category, monthly)
    { id: category.id, active: true, name: category.name, stack_key: category.stack_key, months: Array.new(12) { { planned: monthly, actual: 0 } } }
  end

  def forecast(actual: {}, income: 200, today: Date.new(2026, 1, 1))
    HouseholdFinance::YearForecast.new(@household, year: 2026, periods: @periods, rows: @rows,
      monthly_income: (1..12).to_h { |month| [ month, income ] }, actual_income: actual,
      income_sources: @household.income_sources.includes(:income_schedule_entries).to_a, today: today).call
  end
end
