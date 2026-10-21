require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1CheapReadsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport

  setup do
    travel_to Date.new(2026, 11, 15).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "warm household workspace has bounded SQL and never locks or writes an existing picture" do
    @savings_cohort.update!(savings_challenge_enabled: false)
    seed_household_plan
    assert_cheap_get "/api/v1/workspace", budget: 85
    assert_equal 12, response.parsed_body.dig("budget", "annual_plan", "months").size
    assert_equal 1800.01, response.parsed_body.dig("budget", "annual_plan", "annual_outlook", "upcoming_spikes").sole["expected_irregular"]
  end

  test "warm savings workspace has bounded SQL and never locks or writes" do
    with_daily_operations do
      savings_enroll
      10.times { savings_approve(savings_draft(101)) }
      HouseholdFinance::AnnualBudgetManager.new(@savings_household).ensure_plan!
      assert_cheap_get "/api/v1/workspace", budget: 100
      assert_equal "savings_challenge", response.parsed_body.dig("workspace", "experience_mode")
    end
  end

  test "summary and savings history pages have bounded SQL without locks or writes" do
    with_daily_operations do
      savings_enroll
      savings_plan
      10.times { savings_approve(savings_draft(101)) }
      {
        "/api/v1/savings_challenge" => 65,
        "/api/v1/savings_challenge/entries?limit=10" => 65,
        "/api/v1/savings_challenge/entry_versions?limit=10" => 65,
        "/api/v1/savings_challenge/entry_drafts?limit=10" => 65,
        "/api/v1/savings_challenge/plan_drafts?limit=10" => 65,
        "/api/v1/savings_challenge/plan_versions?limit=10" => 65,
        "/api/v1/savings_challenge/zero_attestations?limit=10" => 65
      }.each { |path, budget| assert_cheap_get path, budget: budget }
    end
  end

  test "daily summary history and candidates do not lock or write" do
    with_daily_operations do
      savings_enroll
      @daily_category = @savings_household.budget_categories.create!(name: "Food", stack_key: "discretionary")
      daily_approve(daily_stage(2501))
      assert_cheap_get "/api/v1/savings_challenge/daily", budget: 100
      assert_equal 2501, response.parsed_body.dig("day", "reported_spend_cents")
      assert_cheap_get "/api/v1/savings_challenge/daily/records?collection=purchases", budget: 100
      assert_equal 1, response.parsed_body.fetch("records").size
      assert_cheap_get "/api/v1/savings_challenge/daily/candidates", budget: 100
      assert_equal 1, response.parsed_body.fetch("records").size
    end
  end

  test "fresh household first GET initializes one plan and returns persisted numeric IDs" do
    @savings_cohort.update!(savings_challenge_enabled: false)
    @savings_household.destroy!
    headers = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
    assert_difference("Household.count", 1) do
      assert_difference("BudgetYear.count", 1) do
        assert_difference("BudgetPeriod.count", 12) { get "/api/v1/workspace", headers: headers }
      end
    end
    assert_response :success
    @savings_household = Household.find(response.parsed_body.dig("workspace", "household_id"))
    ids = response.parsed_body.dig("budget", "annual_plan", "months").pluck("id")
    assert_equal 12, ids.size
    assert ids.all? { |id| id.is_a?(Integer) && id.positive? }
    assert_equal ids.sort, BudgetPeriod.where(budget_year: @savings_household.budget_years).pluck(:id).sort
    assert_nil response.parsed_body.dig("workspace", "setup_values", "emergency_fund")
    assert_no_difference([ "BudgetYear.count", "BudgetPeriod.count", "BudgetAllocation.count" ]) do
      assert_cheap_get "/api/v1/workspace", budget: 85
    end
    assert_equal ids, response.parsed_body.dig("budget", "annual_plan", "months").pluck("id")
  end

  test "a missing period is initialized once without changing existing manual cents" do
    @savings_cohort.update!(savings_challenge_enabled: false)
    seed_household_plan
    year = @savings_household.budget_years.sole
    december = year.budget_periods.find_by!(starts_on: Date.new(2026, 12, 1))
    december.destroy!
    headers = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
    assert_difference("BudgetPeriod.count", 1) { get "/api/v1/workspace", headers: headers }
    assert_response :success
    assert response.parsed_body.dig("budget", "annual_plan", "months").all? { |month| month["id"].is_a?(Integer) }
    assert_equal 12, year.budget_periods.count
    assert_cheap_get "/api/v1/workspace", budget: 85
  end

  private

  def assert_cheap_get(path, budget:)
    headers = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
    get path, headers: headers
    assert_response :success
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get path, headers: headers }
    assert_response :success
    assert_operator statements.size, :<=, budget, "#{path}: #{statements.size} uncached statements (budget #{budget})\n#{statements.join("\n")}"
    assert_empty statements.grep(/FOR UPDATE/i), path
    assert_empty statements.grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i), path
  end

  def seed_household_plan
    household = @savings_household
    household.income_sources.create!(label: "Pay", source_type: "job", amount_cents: 620_001, cadence: "monthly", starts_on: Date.new(2026, 1, 1))
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 230_001, cadence: "monthly")
    household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 165_001, balance_known: true)
    household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 240_001, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 12_001, debt_summary_minimum_payment_known: true)
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    category = manager.create_category!(name: "Holidays", stack_key: "sinking_expected", monthly_amount: 0)
    year = manager.ensure_plan!
    december = year.budget_periods.find_by!(starts_on: Date.new(2026, 12, 1))
    BudgetAllocation.find_by!(budget_period: december, budget_category: category).update!(planned_amount_cents: 180_001, source: "manual")
    november = year.budget_periods.find_by!(starts_on: Date.new(2026, 11, 1))
    transaction = household.household_transactions.create!(budget_period: november, occurred_on: november.starts_on, merchant: "Market",
      total_amount_cents: 12_642, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 12_642)
    household.transaction_drafts.create!(occurred_on: november.starts_on, merchant: "Pending Market", total_amount_cents: 8250, source_type: "manual_ui", status: "pending")
  end
end
