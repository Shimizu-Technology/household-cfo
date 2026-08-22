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

  test "describes zero monthly surplus as breakeven" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "breakeven-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Breakeven household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 300_000, cadence: "monthly")
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")

    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "Why is my readiness Red?").call

    assert_includes answer, "cash flow is at breakeven"
    assert_includes answer, "cash-flow margin and runway problem"
    refute_includes answer, "short by $0.00"
  end

  test "recognizes natural get to yellow phrasing as a readiness plan" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "get-to-yellow-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Readiness plan household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 150_000)
    household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)

    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "How do I get to yellow?").call

    assert_includes answer, "approved household numbers"
    assert_includes answer, "yellow gap"
    assert_includes answer, "Next CFO move"
  end

  test "protects an existing surplus when asked what to focus on first this month" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "monthly-focus-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Monthly focus household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 310_000, cadence: "monthly")
    household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "Based on my income, spending, and goal, what should I focus on first this month?"
    ).call

    assert_includes answer, "surplus you already have, not creating one"
    assert_includes answer, "monthly income is $5,000"
    assert_includes answer, "monthly outflow is $3,100"
    assert_includes answer, "baseline surplus is already positive by $1,900"
    assert_includes answer, "review any expenses you reported to Mia or entered manually"
    refute_includes answer, "bank activity"
    refute_match(/reduce .* to create a surplus/i, answer)
  end

  test "breakeven coaching does not require bank activity when no bank is connected" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "manual-breakeven-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Manual breakeven household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 300_000, cadence: "monthly")
    household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")

    answer = HouseholdFinance::MiaCoachAnswerer.new(household, "What should I focus on first this month?").call

    assert_includes answer, "Review any expenses you reported to Mia or entered manually"
    refute_includes answer, "bank activity"
  end
end
