require "test_helper"

class HouseholdFinanceMiaReadOnlyPlanAnswererTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "multipart-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Multipart household", primary_goal: "Protect the household plan")
    @household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 850_000, cadence: "monthly")
    @household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 500_000, cadence: "monthly")
    @household.expense_items.create!(label: "Flexible", stack_key: "discretionary", amount_cents: 100_000, cadence: "monthly")
    @household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_800_000)
    @household.debts.create!(label: "Card", debt_type: "credit_card", balance_cents: 400_000, minimum_payment_cents: 20_000, interest_rate_percent: 22.5)
    @household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)
    @household.update!(confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
    @annual_plan = @manager.plan_data
  end

  test "answers all six parts in order without creating financial records or drafts" do
    plan = {
      title: "Six household questions",
      items: [
        item("coaching", "Why is my readiness Red?"),
        item("coaching", "How is safe-to-spend calculated?"),
        item("budget_question", "Are we on track with the budget this month?"),
        item("spending_report", "How was my spending this month?"),
        item("transaction_lookup", "How many transactions were at Amazon this month?"),
        item("pending_drafts", "What's pending?")
      ]
    }
    counts = financial_counts

    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: plan,
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    assert_equal counts, financial_counts
    assert_equal 6, result.presentation.fetch(:sections).length
    assert_equal (1..6).map { |number| "part-#{number}" }, result.presentation.fetch(:sections).pluck(:id)
    (1..6).each { |number| assert_includes result.answer, "#{number}. " }
    assert_equal "saved_household", result.presentation.fetch(:basis)
    refute_includes result.answer, "could not answer this part safely"
  end

  test "answers a direct safe-to-spend part from the approved snapshot" do
    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: { title: "Safe to spend", items: [ item("budget_question", "How much is safe to spend?") ] },
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    body = result.presentation.fetch(:sections).first.fetch(:body)
    assert_includes body, "safe-to-spend guardrail"
    refute_includes body, "could not answer"
  end

  test "answers ordinary readiness and over-budget questions from saved data" do
    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: {
        title: "Household status",
        items: [
          item("budget_question", "Could you explain my readiness?"),
          item("budget_question", "Would you tell me if I am over budget?")
        ]
      },
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    bodies = result.presentation.fetch(:sections).pluck(:body)
    assert_includes bodies.first, "approved readiness"
    assert_includes bodies.second, "confirmed actuals"
    refute_includes bodies.join(" "), "could not answer"
    assert_equal "saved_household", result.presentation.fetch(:basis)
  end

  test "keeps bonus medical bill and debt values local and explicitly unsaved" do
    plan = {
      title: "Three scenarios",
      items: [
        scenario_item("one_time_income", "Bonus", "1000"),
        scenario_item("essential_expense", "Medical bill", "1200"),
        scenario_item("extra_debt_payment", "Extra card payment", "500")
      ]
    }
    before = financial_counts

    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: plan,
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    assert_equal before, financial_counts
    assert_equal "scenario_only", result.presentation.fetch(:basis)
    assert_equal [ "$1,000", "$1,200", "$500" ], result.presentation.dig(:scenario, :values).pluck(:display_value)
    assert_equal 3, result.answer.scan(/Scenario only/).length
    assert_includes result.answer, "not saved or approved income"
    assert_includes result.answer, "not a saved bill"
    assert_includes result.answer, "not scheduled, paid, or deducted"
    assert_equal 850_000, @household.income_sources.sum(:amount_cents)
    assert_equal 400_000, @household.debts.sum(:balance_cents)
  end

  test "keeps every action result absent and answers later parts when one part fails" do
    plan = {
      title: "Part failure",
      items: [
        scenario_item("unsupported", "Unknown scenario", "100"),
        scenario_item("purchase", "Laptop", "900")
      ]
    }
    before = financial_counts

    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: plan,
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    assert_equal before, financial_counts
    assert_equal 2, result.presentation.fetch(:sections).length
    assert_includes result.presentation.dig(:sections, 0, :body), "could not answer this part safely"
    assert_includes result.presentation.dig(:sections, 1, :body), "Scenario only"
  end

  test "does not claim a scenario basis when every scenario answer fails" do
    result = HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
      @household,
      plan: { title: "Failed scenario", items: [ scenario_item("unsupported", "Unknown scenario", "100") ] },
      annual_budget_manager: @manager,
      annual_plan: @annual_plan,
      reference_month: Date.current.month
    ).call

    assert_equal "saved_household", result.presentation.fetch(:basis)
    refute result.presentation.key?(:scenario)
    assert_includes result.presentation.dig(:sections, 0, :body), "could not answer this part safely"
  end

  test "compacts a long generated section before chat-message persistence" do
    answerer = Object.new
    answerer.define_singleton_method(:call) { "Detailed answer " + ("å" * 3_000) }
    plan = { title: "Long answer", items: [ item("coaching", "Explain my readiness") ] }

    result = with_coach_answerer(answerer) do
      HouseholdFinance::MiaReadOnlyPlanAnswerer.new(
        @household,
        plan: plan,
        annual_budget_manager: @manager,
        annual_plan: @annual_plan,
        reference_month: Date.current.month
      ).call
    end
    session = @household.chat_sessions.create!(user: @user, title: "Ask Mia")
    message = session.chat_messages.create!(role: "assistant", content: result.answer, presentation: result.presentation)

    assert message.persisted?
    assert_operator result.presentation.dig(:sections, 0, :body).bytesize, :<=, HouseholdFinance::MiaReadOnlyPlanAnswerer::MAX_SECTION_BODY_BYTES
    assert_operator JSON.generate(result.presentation).bytesize, :<=, ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH
    assert_operator result.answer.length, :<=, ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH
    assert result.presentation.dig(:sections, 0, :body).end_with?("…")
  end

  private

  def with_coach_answerer(answerer)
    singleton = class << HouseholdFinance::MiaCoachAnswerer; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |*args, **kwargs| answerer }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end

  def item(kind, question)
    { kind: kind, source_text: question, resolved_question: question, basis: "approved", scenario_type: "none", scenario_label: "", amount: "", effective_on: "" }
  end

  def scenario_item(type, label, amount)
    { kind: "scenario", source_text: "What if #{label} is $#{amount}?", resolved_question: "What if #{label} is $#{amount}?", basis: "hypothetical", scenario_type: type, scenario_label: label, amount: amount, effective_on: "" }
  end

  def financial_counts
    {
      budget_years: BudgetYear.count,
      budget_periods: BudgetPeriod.count,
      allocations: BudgetAllocation.count,
      action_drafts: MiaActionDraft.count,
      transaction_drafts: TransactionDraft.count,
      transactions: HouseholdTransaction.count,
      schedules: IncomeScheduleEntry.count,
      income_sources: IncomeSource.count,
      expenses: ExpenseItem.count,
      accounts: Account.count,
      debts: Debt.count
    }
  end
end
