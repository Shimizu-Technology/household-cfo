require "test_helper"

class YearForecastTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "talun-forecast@example.invalid", clerk_id: "talun-forecast")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    @household.accounts.create!(label: "Talun cash", account_type: "checking", balance_cents: 100_000, balance_known: true, balance_as_of_on: "2025-12-31")
    @household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_minimum_payment_known: true, debt_summary_minimum_payment_cents: 0)
    category = @household.budget_categories.create!(name: "Utilities", stack_key: "non_discretionary")
    @periods = (1..12).map { |month| Struct.new(:id, :starts_on).new(month, Date.new(2026, month, 1)) }
    @rows = [ { id: category.id, active: true, name: "Utilities", months: Array.new(12) { { planned: 100 } } } ]
    @household.bills.create!(name: "Power", amount_cents: 8000, due_on: "2026-01-31", repeat_months: 1, budget_category: category)
  end

  test "rolling cash includes category bills once and finds the one time shortfall reason" do
    @household.bills.create!(name: "Car registration", amount_cents: 150_000, due_on: "2026-03-10")
    result = forecast
    assert_equal [ 110_000, 120_000, -20_000 ], result[:months].first(3).map { |month| month[:ending_cents] }
    assert_equal "March", result[:first_short_month][:label]
    assert_includes result[:first_short_month][:reasons], "Car registration"
    assert_equal "2026-02-28", result[:months][1][:bills][0][:due_on]
  end

  test "unknown cash stays unknown" do
    @household.accounts.first.update!(balance_known: false, balance_cents: 0, balance_as_of_on: nil)
    assert_nil forecast[:starting_cash_cents]
    assert_equal "unknown", forecast[:status]
    assert forecast[:months].all? { |month| month[:ending_cents].nil? }
  end

  test "midmonth balances never have the same income added a second time" do
    @household.accounts.first.update!(balance_as_of_on: "2026-01-15")
    assert_nil forecast[:starting_cash_cents]
    assert_equal "unknown", forecast[:status]
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
  end

  test "approved actual replaces plan and partial remains visible" do
    result = forecast(actual: { 1 => { actual_cents: 5000, partial: true } })
    assert_equal 95_000, result[:months][0][:ending_cents]
    assert_equal "approved actual", result[:months][0][:income_basis]
    assert result[:months][0][:actual_partial]
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

  test "Mia uses saved facts for year and dated bills without a write" do
    @household.bills.create!(name: "Talun March fee", amount_cents: 1234, due_on: Date.new(Date.current.year, 3, 10))
    assert_no_difference "Bill.count" do
      answer = HouseholdFinance::YearForecastAnswer.new(@household, "What's due in March?").call
      assert_includes answer, "$12.34"
      assert_includes answer, "March 10"
      assert_includes HouseholdFinance::YearForecastAnswer.new(@household, "Will we make it through the year?").call, "year"
    end
  end

  private

  def forecast(actual: {}, income: 200)
    HouseholdFinance::YearForecast.new(@household, year: 2026, periods: @periods, rows: @rows,
      monthly_income: (1..12).to_h { |month| [ month, income ] }, actual_income: actual, today: Date.new(2026, 1, 1)).call
  end
end
