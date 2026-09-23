require "test_helper"

class HouseholdFinanceDebtStrategyPlannerTest < ActiveSupport::TestCase
  setup do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "debt-plan-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: user, name: "Debt plan household")
    @household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    @household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    @household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 300_000)
    @household.debts.create!(label: "Card A", debt_type: "credit_card", balance_cents: 310_000, minimum_payment_cents: 17_500, interest_rate_percent: 28.9)
    @household.debts.create!(label: "Card B", debt_type: "credit_card", balance_cents: 230_000, minimum_payment_cents: 8_500, interest_rate_percent: 19.5)
  end

  test "compares avalanche and snowball from approved balances and APRs" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "Compare debt avalanche and snowball and tell me which card to pay first."
    ).call

    assert_includes answer, "Avalanche: Card A first"
    assert_includes answer, "28.9% APR"
    assert_includes answer, "Snowball: Card B first"
    assert_includes answer, "$2,300"
    assert_includes answer, "Keep both minimums current"
  end

  test "keeps a tax refund debt question in debt planning" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "I got a $2,000 tax refund. Should I use it on debt? Compare avalanche and snowball."
    ).call

    assert_includes answer, "$2,000"
    assert_includes answer, "Avalanche: Card A first"
    assert_includes answer, "Snowball: Card B first"
    refute_includes answer, "qualified tax professional"
  end

  test "returns a concrete debt plan before generic readiness coaching" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "Give me a concrete three-step plan for my debt."
    ).call

    assert_includes answer, "1. Protect"
    assert_includes answer, "2. Hold"
    assert_includes answer, "3. Send"
    assert_includes answer, "Card A"
  end

  test "uses prior participant scenario details during a follow-up" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "Now give me a concrete three-step plan while my income is down $600 for two months.",
      conversation_messages: [
        { role: "user", content: "Card A is $3,100 at 28.9% APR with a $175 minimum. Card B is $2,300 at 19.5% APR with an $85 minimum." }
      ]
    ).call

    assert_includes answer, "$600 temporary monthly income drop"
    assert_includes answer, "two months"
    assert_includes answer, "Card A"
    assert_includes answer, "Card B"
    assert_includes answer, "participant-stated scenario"
  end

  test "combines saved and unsaved scenario debts in a complex refund and income-drop question" do
    @household.debts.where(label: "Card B").delete_all

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "I have Card A saved at $3,100 with a 28.9% APR and a $175 minimum. I also have a personal loan that I have not entered yet: $8,000 at 11.5% APR with a $240 minimum. My take-home income is temporarily dropping by $900 per month for the next three months, but I expect a $2,000 tax refund next month. Compare avalanche and snowball and give me a concrete three-step debt plan."
    ).call

    assert_includes answer, "Card A (saved)"
    assert_includes answer, "personal loan (scenario only, not saved)"
    assert_includes answer, "Avalanche: Card A first"
    assert_includes answer, "Snowball: Card A first"
    assert_includes answer, "$415 total"
    assert_includes answer, "$900 temporary monthly income drop for three months"
    assert_includes answer, "$2,000 tax refund"
    assert_includes answer, "does not determine tax eligibility or obligations"
    refute_includes answer, "using any of the $3,100"
  end

  test "keeps the refund amount paired with the refund when another dollar amount follows" do
    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "Please include the $2,000 tax refund and the three-month $900 income drop in my debt plan."
    ).call

    assert_includes answer, "Treat the $2,000 tax refund"
    refute_includes answer, "Treat the $900 tax refund"
  end

  test "does not route an unrelated readiness follow-up from an assistant debt mention" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "Help me make a plan to get to Yellow.",
      conversation_messages: [
        { role: "assistant", content: "Keep all debt minimums current while you build runway." }
      ]
    ).call

    assert_nil answer
  end
end
