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
