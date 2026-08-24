require "test_helper"

class HouseholdFinanceSnapshotBuilderTest < ActiveSupport::TestCase
  test "readiness tone uses the saved runway target" do
    household = household_with_runway(runway_months: 7, target_months: 12)

    snapshot = HouseholdFinance::SnapshotBuilder.new(household).call

    assert_equal 7.0, snapshot.fetch(:runway_months)
    assert_equal 12.0, snapshot.fetch(:target_runway_months)
    assert_equal "yellow", snapshot.fetch(:readiness_tone)
  end

  test "readiness turns green when runway reaches the saved target" do
    household = household_with_runway(runway_months: 12, target_months: 12)

    snapshot = HouseholdFinance::SnapshotBuilder.new(household).call

    assert_equal 12.0, snapshot.fetch(:target_runway_months)
    assert_equal "green", snapshot.fetch(:readiness_tone)
  end

  test "red readiness reserves positive surplus for stability instead of calling it safe to spend" do
    household = household_with_runway(runway_months: 1, target_months: 6)

    snapshot = HouseholdFinance::SnapshotBuilder.new(household).call

    assert_equal "red", snapshot.fetch(:readiness_tone)
    assert_operator snapshot.fetch(:baseline_surplus_cents), :>, 0
    assert_equal 0, snapshot.fetch(:safe_to_spend_cents)
  end

  test "yellow readiness can expose a bounded discretionary amount" do
    household = household_with_runway(runway_months: 3, target_months: 6)

    snapshot = HouseholdFinance::SnapshotBuilder.new(household).call

    assert_equal "yellow", snapshot.fetch(:readiness_tone)
    assert_equal (snapshot.fetch(:baseline_surplus_cents) * 0.4).round, snapshot.fetch(:safe_to_spend_cents)
  end

  test "preloaded income sources load all schedule entries in one query" do
    household = household_with_runway(runway_months: 3, target_months: 6)
    second_source = household.income_sources.create!(
      label: "Secondary income",
      source_type: "job",
      amount_cents: 200_000,
      cadence: "monthly"
    )
    household.income_sources.first.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 1_100_000,
      cadence: "monthly",
      effective_on: Date.current.beginning_of_month
    )
    second_source.income_schedule_entries.create!(
      entry_type: "one_time",
      amount_cents: 50_000,
      cadence: "one_time",
      effective_on: Date.current.beginning_of_month
    )
    household.income_sources.load

    schedule_queries = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      schedule_queries << payload[:sql] if payload[:sql].include?("income_schedule_entries")
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      HouseholdFinance::SnapshotBuilder.new(household).call
    end

    assert_equal 1, schedule_queries.length
  end

  test "uses the active month allocation as the dashboard and Mia cash-flow source of truth" do
    household = household_with_runway(runway_months: 3, target_months: 6)
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    plan = manager.plan_data
    current_index = Date.current.month - 1
    allocation_id = plan.fetch(:rows).first.fetch(:months).fetch(current_index).fetch(:allocation_id)
    allocation = BudgetAllocation.find(allocation_id)

    manager.update_allocation!(allocation, 6_500)
    snapshot = HouseholdFinance::SnapshotBuilder.new(household, annual_budget_manager: manager).call

    assert_equal 650_000, snapshot.fetch(:total_expenses_cents)
    assert_equal 350_000, snapshot.fetch(:baseline_surplus_cents)
    assert_equal "red", snapshot.fetch(:readiness_tone)
    assert_equal 0, snapshot.fetch(:safe_to_spend_cents)

    data = HouseholdFinance::DataPresenter.new(household).app_data
    assert_equal 6_500, data.dig(:dashboard, :summary, :fixed_expenses)
    assert_equal 6_500, data.dig(:budget, :total_monthly_outflow)
    assert_equal 3_500, data.dig(:budget, :baseline_surplus)
    assert_equal 6_500, data.dig(:budget, :stacks, 0, :amount)

    mia_answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "How is safe-to-spend calculated?",
      annual_budget_manager: manager
    ).call
    assert_includes mia_answer, "$6,500 category plan"
    assert_includes mia_answer, "$3,500 baseline surplus"
    assert_includes mia_answer, "safe-to-spend guardrail is $0"
  end

  test "does not let an allocation in another month change the active month snapshot" do
    household = household_with_runway(runway_months: 3, target_months: 6)
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    plan = manager.plan_data
    other_index = Date.current.month == 1 ? 1 : 0
    allocation_id = plan.fetch(:rows).first.fetch(:months).fetch(other_index).fetch(:allocation_id)

    manager.update_allocation!(BudgetAllocation.find(allocation_id), 6_500)
    snapshot = HouseholdFinance::SnapshotBuilder.new(household, annual_budget_manager: manager).call

    assert_equal 100_000, snapshot.fetch(:total_expenses_cents)
    assert_equal 900_000, snapshot.fetch(:baseline_surplus_cents)
  end

  private

  def household_with_runway(runway_months:, target_months:)
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Runway household")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 1_000_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 100_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: (runway_months * 100_000).round)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: target_months, priority: 1)
    household
  end
end
