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

  test "explains safe-to-spend from the exact approved formula" do
    household = create_yellow_household

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "How exactly is my safe-to-spend amount calculated?"
    ).call

    assert_includes answer, "$8,500"
    assert_includes answer, "$7,845"
    assert_includes answer, "$655"
    assert_includes answer, "40%"
    assert_includes answer, "$262"
    assert_includes answer, "not a purchase amount"
  end

  test "answers both sides of a compound purchase and extra debt decision" do
    household = create_yellow_household

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "Can I take a $900 trip and make a $750 extra debt payment this month? Show the math against safe-to-spend and baseline surplus."
    ).call

    assert_includes answer, "$1,650"
    assert_includes answer, "$638"
    assert_includes answer, "$995"
    assert_includes answer, "not a second safe-to-spend allowance"
    assert_includes answer, "Nothing is approved"
  end

  test "associates compound amounts globally when the purchase amount appears later" do
    household = create_yellow_household

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "Can I take a trip and make a $750 extra debt payment this month if the trip costs $900?"
    ).call

    assert_includes answer, "proposed purchase is $900"
    assert_includes answer, "extra debt payment is $750"
    assert_includes answer, "together they total $1,650"
  end

  test "holds safe-to-spend at zero when a positive-surplus household is still Red" do
    household = create_yellow_household
    household.accounts.find_by!(account_type: "emergency_fund").update!(balance_cents: 0)

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "How exactly is my safe-to-spend amount calculated?"
    ).call

    assert_includes answer, "safe-to-spend guardrail is $0"
    assert_includes answer, "$655 baseline surplus"
    assert_includes answer, "Red readiness holds safe-to-spend at $0"
    assert_includes answer, "40% rule is not active yet"
    refute_includes answer, "$655 × 40% = $0"
  end

  test "does not apply the percentage formula to a negative baseline surplus" do
    household = create_yellow_household
    household.expense_items.first.update!(amount_cents: 900_000)

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      household,
      "How exactly is my safe-to-spend amount calculated?"
    ).call

    assert_includes answer, "safe-to-spend guardrail is $0"
    assert_includes answer, "-$1,420 baseline surplus"
    assert_includes answer, "zero or negative surplus does not create discretionary room"
    refute_includes answer, "-$1,420 × 40% = $0"
  end

  private

  def create_yellow_household
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "yellow-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Yellow household")
    household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 850_000, cadence: "monthly")
    household.expense_items.create!(label: "Category plan", stack_key: "non_discretionary", amount_cents: 692_500, cadence: "monthly")
    household.debts.create!(label: "Debt", debt_type: "credit_card", balance_cents: 10_000_00, minimum_payment_cents: 92_000)
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 2_509_000)
    household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)
    household
  end
end
