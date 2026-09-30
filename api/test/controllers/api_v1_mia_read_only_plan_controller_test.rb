require "test_helper"

class ApiV1MiaReadOnlyPlanControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "mia-read-only-plan-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 850_000, cadence: "monthly")
    @household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 500_000, cadence: "monthly")
    @household.expense_items.create!(label: "Flexible", stack_key: "discretionary", amount_cents: 100_000, cadence: "monthly")
    @household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_800_000)
    @household.debts.create!(label: "Card", debt_type: "credit_card", balance_cents: 400_000, minimum_payment_cents: 20_000, interest_rate_percent: 22.5)
    @household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)
    @household.update!(
      primary_goal: "Protect the household plan",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s)
    )
    HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year).plan_data
  end

  test "create history and idempotent replay preserve the read-only presentation without financial changes" do
    message = "Why is my readiness Yellow? Also, what if I buy a laptop for $900?"
    resolver = resolver_for(
      message,
      [
        plan_item("coaching", "Why is my readiness Yellow?"),
        scenario_item("purchase", "what if I buy a laptop for $900?", "Laptop", "900")
      ]
    )
    counts = financial_counts

    with_intent_resolver(resolver) do
      assert_difference("ChatMessage.count", 2) do
        post "/api/v1/mia/messages",
          params: { message: message, request_id: "read-only-plan-#{SecureRandom.uuid}" },
          headers: auth_headers,
          as: :json
      end
    end

    assert_response :created
    created = JSON.parse(response.body)
    presentation = created.dig("assistant_message", "presentation")
    request_id = @household.chat_sessions.find_by!(user: @user).mia_message_requests.last.request_key

    assert_nil created.fetch("mia_action_draft")
    assert_nil created.fetch("transaction_draft")
    assert_nil created.fetch("spending_report")
    assert_equal 1, presentation.fetch("version")
    assert_equal "read_only_answer", presentation.fetch("kind")
    assert_equal "saved_household_plus_scenario", presentation.fetch("basis")
    assert_equal %w[part-1 part-2], presentation.fetch("sections").pluck("id")
    assert_equal "$900", presentation.dig("scenario", "values", 0, "display_value")
    assert_includes created.dig("assistant_message", "content"), "1. Household CFO guidance"
    assert_includes created.dig("assistant_message", "content"), "2. Purchase scenario"
    assert_equal counts, financial_counts

    get "/api/v1/mia/messages", headers: auth_headers, as: :json

    assert_response :success
    historical = JSON.parse(response.body).fetch("messages").find { |entry| entry.fetch("id") == created.dig("assistant_message", "id") }
    assert_equal presentation, historical.fetch("presentation")

    with_intent_resolver(resolver) do
      assert_no_difference("ChatMessage.count") do
        post "/api/v1/mia/messages",
          params: { message: message, request_id: request_id },
          headers: auth_headers,
          as: :json
      end
    end

    assert_response :created
    replayed = JSON.parse(response.body)
    assert_equal created, replayed
    assert_equal presentation, replayed.dig("assistant_message", "presentation")
    assert_equal counts, financial_counts
  end

  test "a cold confirmed scenario does not materialize budget records" do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "mia-cold-scenario-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    @household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    @household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 600_000)
    @household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)
    @household.update!(primary_goal: "Build runway", confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    message = "What if I buy a $1,000 laptop next month?"
    next_month = Date.current.next_month.beginning_of_month
    resolver = resolver_for(
      message,
      [ scenario_item("purchase", message, "Laptop", "1000").merge(effective_on: next_month.iso8601) ]
    )
    preview = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year).read_only_plan_data

    assert_equal 0, @household.budget_years.count
    assert resolver.call.read_only_plan?
    refute preview.fetch(:plan_available)
    assert_equal 3_000.0, preview.fetch(:rows).find { |row| row.fetch(:name) == "Essentials" }.dig(:months, Date.current.month - 1, :planned)
    with_intent_resolver(resolver) do
      post "/api/v1/mia/messages",
        params: { message: message },
        headers: auth_headers,
        as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_nil body.fetch("budget")
    assert_nil body.fetch("mia_action_draft")
    assert_nil body.fetch("transaction_draft")
    assert_includes body.dig("assistant_message", "content"), "for #{next_month.strftime('%B %Y')}"
    assert_includes body.dig("assistant_message", "content"), "safe-to-spend guardrail is $0"
    assert_equal 0, @household.budget_years.count
    assert_equal 0, BudgetPeriod.joins(:budget_year).where(budget_years: { household_id: @household.id }).count
    assert_equal 0, BudgetAllocation.joins(budget_category: :household).where(households: { id: @household.id }).count
  end

  private

  def resolver_for(message, items)
    result = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "coaching",
      confidence: 0.99,
      continuation: false,
      resolved_message: message,
      needs_clarification: false,
      clarification: "",
      topic: { type: "read_only_plan", title: "Read-only household questions", subject: "Household plan" },
      action: { type: "none" },
      read_only_plan: { title: "Household questions", items: items },
      source: "model"
    )
    Object.new.tap { |resolver| resolver.define_singleton_method(:call) { result } }
  end

  def plan_item(kind, question)
    {
      kind: kind,
      source_text: question,
      resolved_question: question,
      basis: "approved",
      scenario_type: "none",
      scenario_label: "",
      amount: "",
      effective_on: ""
    }
  end

  def scenario_item(type, source, label, amount)
    {
      kind: "scenario",
      source_text: source,
      resolved_question: source,
      basis: "hypothetical",
      scenario_type: type,
      scenario_label: label,
      amount: amount,
      effective_on: ""
    }
  end

  def with_intent_resolver(resolver)
    singleton = class << HouseholdFinance::MiaIntentResolver; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) { |**_kwargs| resolver }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.method_defined?(:new)
    singleton.define_method(:new, original_new)
  end

  def auth_headers
    { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  def financial_counts
    {
      budget_years: BudgetYear.count,
      budget_periods: BudgetPeriod.count,
      allocations: BudgetAllocation.count,
      action_drafts: MiaActionDraft.count,
      action_items: MiaActionItem.count,
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
