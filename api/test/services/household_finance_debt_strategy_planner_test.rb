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
    @household.update!(
      primary_goal: "Pay down debt safely",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s)
    )
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

  test "never targets a paid-off high APR debt" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 0)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Compare avalanche and snowball.").call

    assert_includes answer, "Avalanche: Card B first"
    assert_includes answer, "Snowball: Card B first"
    refute_includes answer, "Card A first"
    refute_match(/surplus to Card A/, answer)
  end

  test "caps extra principal after the target minimum without promising payoff" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 10_000, minimum_payment_cents: 2_500)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.").call

    assert_includes answer, "up to $75 from the current monthly surplus to Card A"
    assert_includes answer, "verify the current statement or payoff amount"
    refute_match(/paid off (?:in|by)/i, answer)
  end

  test "does not add principal when the recorded minimum covers the target balance" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 2_500, minimum_payment_cents: 2_500)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Give me a debt plan.").call

    assert_includes answer, "minimum already covers its recorded balance"
    refute_includes answer, "3. Send"
  end

  test "unknown balances block rankings and numeric principal recommendations" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 0, balance_known: false)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Compare avalanche and snowball. I got a $2,000 bonus.").call

    assert_includes answer, "a missing balance is not $0"
    refute_includes answer, "Avalanche:"
    refute_includes answer, "Snowball:"
    refute_includes answer, "3. Send"
    refute_includes answer, "After that guardrail"
  end

  test "missing APR prevents definitive avalanche ranking but allows known balance snowball" do
    @household.debts.find_by!(label: "Card B").update!(interest_rate_percent: nil)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Compare avalanche and snowball.").call

    refute_includes answer, "Avalanche: Card A first"
    assert_includes answer, "Avalanche needs each outstanding debt's APR"
    assert_includes answer, "Snowball: Card B first"
    assert_includes answer, "this is a snowball target; confirm missing APRs"
  end

  test "coach debt versus savings guidance does not display incomplete debt as a known total" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 0, balance_known: false)

    [ "Compare avalanche and snowball.", "Should I put extra money toward debt or savings?" ].each do |message|
      answer = HouseholdFinance::MiaCoachAnswerer.new(@household, message, ensure_plan: false).call

      assert_includes answer, "missing debt balance as $0"
      refute_includes answer, "Avalanche:"
      refute_includes answer, "debt entered is"
      refute_includes answer, "3. Send"
    end
    assert_equal 0, @household.budget_years.count
  end

  test "zero APR is a known rate and paid-off missing APR does not block the outstanding ranking" do
    @household.debts.find_by!(label: "Card A").update!(balance_cents: 0, interest_rate_percent: nil)
    @household.debts.find_by!(label: "Card B").update!(interest_rate_percent: 0)

    answer = HouseholdFinance::DebtStrategyPlanner.new(@household, "Compare avalanche and snowball.").call

    assert_includes answer, "Avalanche: Card B first"
    assert_includes answer, "0% APR"
    refute_includes answer, "APR is still missing"
  end

  test "confirmed zero portfolio has no outstanding target or extra payment instruction" do
    @household.debts.each { |debt| debt.update!(balance_cents: 0, minimum_payment_cents: 0) }

    answer = HouseholdFinance::MiaCoachAnswerer.new(@household, "Compare avalanche and snowball.").call

    assert_includes answer, "All listed balances are confirmed at $0"
    refute_includes answer, "Avalanche:"
    refute_includes answer, "Snowball:"
    refute_includes answer, "3. Send"
  end

  test "read-only coaching answers accurately without materializing a cold budget plan" do
    assert_equal 0, @household.budget_years.count
    assert_equal 0, BudgetPeriod.joins(:budget_year).where(budget_years: { household_id: @household.id }).count
    assert_equal 0, BudgetAllocation.joins(budget_category: :household).where(households: { id: @household.id }).count

    answer = HouseholdFinance::MiaCoachAnswerer.new(
      @household,
      "Compare debt avalanche and snowball and tell me which card to pay first.",
      ensure_plan: false
    ).call

    assert_includes answer, "Avalanche: Card A first"
    assert_includes answer, "Snowball: Card B first"
    assert_includes answer, "up to $1,740 from the current monthly surplus"
    assert_equal 0, @household.budget_years.count
    assert_equal 0, BudgetPeriod.joins(:budget_year).where(budget_years: { household_id: @household.id }).count
    assert_equal 0, BudgetAllocation.joins(budget_category: :household).where(households: { id: @household.id }).count
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

  test "does not route an unrelated registration question after participant debt context" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "What about car registration next month?",
      conversation_messages: [
        { role: "user", content: "Help me compare my credit card debt using avalanche and snowball." }
      ]
    ).call

    assert_nil answer
  end

  test "does not treat paying down debt as a temporary income reduction" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "I am paying down $300 on my debt this month. Give me a concrete debt plan."
    ).call

    refute_includes answer, "temporary monthly income drop"
  end

  test "still recognizes a genuine pay reduction" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "My pay is down $300 for two months. Give me a concrete debt plan."
    ).call

    assert_includes answer, "$300 temporary monthly income drop for two months"
  end

  test "does not calculate a temporary-drop surplus while a debt minimum is unknown" do
    @household.debts.find_by!(label: "Card B").update!(minimum_payment_cents: 0, minimum_payment_known: false)

    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "My pay is down $300 for two months. Give me a concrete debt plan."
    ).call

    assert_includes answer, "$300 temporary monthly income drop for two months"
    assert_includes answer, "verified surplus is unavailable"
    refute_includes answer, "modeled monthly surplus becomes"
  end

  test "recognizes a direct plan request after recent debt context" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "What should I do?",
      conversation_messages: [
        { role: "user", content: "Help me compare my credit card debt using avalanche and snowball." }
      ]
    ).call

    assert_includes answer, "Avalanche:"
    assert_includes answer, "Snowball:"
  end

  test "does not treat a direct question about an unrelated topic as a debt followup" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "What should I do about car registration next month?",
      conversation_messages: [
        { role: "user", content: "Help me compare my credit card debt using avalanche and snowball." }
      ]
    ).call

    assert_nil answer
  end

  test "does not double count a repeated scenario debt when the participant changes the qualifier" do
    answer = HouseholdFinance::DebtStrategyPlanner.new(
      @household,
      "I also have a personal loan I have not saved: $8,000 at 11.5% APR with a $240 minimum. Compare avalanche and snowball.",
      conversation_messages: [
        { role: "user", content: "I also have a personal loan that I have not entered yet: $8,000 at 11.5% APR with a $240 minimum." }
      ]
    ).call

    assert_equal 1, answer.scan("personal loan (scenario only, not saved)").length
    assert_includes answer, "$500 total"
    refute_includes answer, "$740 total"
  end
end
