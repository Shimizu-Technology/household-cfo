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
