require "test_helper"

class HouseholdFinanceMiaCoachAnswererTest < ActiveSupport::TestCase
  test "routes a baseline color question through approved readiness facts" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "readiness-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Readiness household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 150_000)
    household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)

    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Why is my baseline yellow?").call

    assert_includes answer, "readiness is Red, not Yellow"
    assert_includes answer, "mainly a runway problem"
    refute_match(/your baseline is yellow/i, answer)
  end
end
