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
