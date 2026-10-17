require "test_helper"

# End-to-end regressions from the October 2026 Mia chat QA pass. The provider is
# stubbed (or absent) so every reply comes from Rails-owned routing and facts.
class ApiV1MiaQaChatRegressionsTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup { travel_to Time.zone.local(2026, 10, 16, 12) }
  teardown { travel_back }

  # F6
  test "call us with a goal clause drafts a short household name and the goal" do
    user, _household = participant
    post_message(user, "call us the cruz ohana lol and our main goal is to build an emergency fund of like 3 months")

    assert_response :created
    items = response.parsed_body.dig("mia_action_draft", "items").to_a
    name = items.find { |item| item.dig("payload", "key") == "household_name" }
    goal = items.find { |item| item.dig("payload", "key") == "primary_goal" }
    assert_equal "The Cruz Ohana", name&.dig("payload", "value"), response.parsed_body.inspect
    assert_equal "Build an emergency fund of like 3 months", goal&.dig("payload", "value")
  end

  # F8
  test "after setup the gate names every missing piece and no debt becomes a reviewed zero summary" do
    user, household = participant
    complete_setup(household)
    with_resolved_intent(coaching_intent("How much is safe to spend this month?")) do
      post_message(user, "ok we done with setup? so how much is safe to spend this month")
    end
    answer = reply
    assert_includes answer, "debt minimum"
    assert_includes answer, "liquid account picture is incomplete"
    assert_includes answer, "we have no debt"

    assert_difference -> { household.mia_action_drafts.count }, 1 do
      post_message(user, "we dont have any debt, no credit cards nothing")
    end
    draft = household.mia_action_drafts.order(:id).last
    assert_equal "debt_plan", draft.draft_type
    refute HouseholdFinance::DebtPortfolio.new(household.reload).minimum_payment_known?, "nothing applies before review"
  end

  # F7
  test "spending follow-ups answer the named category or merchant with consistent October numbers" do
    user, household = participant
    complete_setup(household)
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    dining = manager.create_category!(name: "Dining out", stack_key: "discretionary", monthly_amount: 200)
    car = manager.create_category!(name: "Car repair", stack_key: "sinking_unexpected", monthly_amount: 100)
    confirmed(household, manager, dining, "Jollibee", 2_775, Date.new(2026, 10, 3))
    confirmed(household, manager, dining, "Capricciosa", 6_420, Date.new(2026, 10, 12))
    confirmed(household, manager, car, "Tommy's Auto Repair", 64_000, Date.new(2026, 9, 20))

    with_resolved_intent(report_intent("How much did we spend on dining out this month?")) { post_message(user, "and dining out?") }
    assert_includes reply, "Dining out has $91.95 in confirmed spending"
    refute_includes reply, "Top actual categories"
    refute_includes reply, "synced bank activity"

    with_resolved_intent(report_intent("How much of this month's spending was at Jollibee?")) { post_message(user, "how much of that was jollibee") }
    assert_includes reply, "confirmed spending at Jollibee is $27.75"

    with_resolved_intent(report_intent("How much did we spend on car repair in September?")) do
      post_message(user, "hmm ok. go back to the car repair, how much did we spend on that in september")
    end
    assert_includes reply, "Car repair has $640 in confirmed spending"
    refute_includes reply, "real baseline need"

    with_resolved_intent(report_intent("How much did we spend in October?")) { post_message(user, "how much did we spend so far in october") }
    october = reply
    with_resolved_intent(report_intent("How much did we spend this month?")) { post_message(user, "how much did we spend this month") }
    this_month = reply
    assert_equal october[/You are \$[\d,.]+ (?:under|over)/], this_month[/You are \$[\d,.]+ (?:under|over)/]
    assert_includes october, "Oct 1, 2026 – Oct 16, 2026"
  end

  # F9
  test "three purchases in one message become three pending reviews and no actuals" do
    user, household = participant
    complete_setup(household)
    message = "yesterday i got gas at shell for 45 and then kfc 18.50 for the kids and 32 at ace hardware"
    plan = {
      title: "Reported expenses",
      actions: [
        expense("gas at shell for 45", "Shell", "45"),
        expense("kfc 18.50", "KFC", "18.50"),
        expense("32 at ace hardware", "Ace Hardware", "32")
      ]
    }

    assert_difference -> { household.transaction_drafts.pending.count }, 3 do
      assert_no_difference -> { household.household_transactions.count } do
        with_provider(intent: "action_plan", write_plan: plan) { post_message(user, message) }
      end
    end
    assert_response :created
    assert_includes reply, "I drafted 3 expense reviews"
    %w[Shell KFC Ace\ Hardware].each { |merchant| assert_includes reply, merchant }
    refute_includes reply, "one change at a time"
    assert_equal [ 4_500, 1_850, 3_200 ], household.transaction_drafts.pending.order(:id).pluck(:total_amount_cents)
    assert_equal [ Date.new(2026, 10, 15) ], household.transaction_drafts.pending.distinct.pluck(:occurred_on)
    assert response.parsed_body.dig("budget", "annual_plan", "pending_transaction_drafts").length >= 3
  end

  # F10
  test "moving a pending draft to another category does not ask for the amount again" do
    user, household = participant
    complete_setup(household)
    fixed = household.budget_categories.find_by!(name: "Fixed essentials")
    flexible = household.budget_categories.find_by!(name: "Flexible spending")
    draft = household.transaction_drafts.create!(occurred_on: Date.new(2026, 10, 16), merchant: "McDonald's",
      total_amount_cents: 2_700, status: "pending", source_type: "manual_chat", raw_input: "spent 27 at mcdonalds", budget_category: flexible)

    with_provider(intent: "transaction_draft_action", action: { type: "update_transaction_draft", draft_id: draft.id,
      category_id: fixed.id, category_name: "Fixed essentials", amount: "27" }) do
      post_message(user, "put the mcdonalds one under fixed essentials")
    end

    assert_response :created
    refute_includes reply, "restate the amount"
    assert_equal fixed.id, draft.reload.budget_category_id
    assert_equal 2_700, draft.total_amount_cents
    assert_equal "pending", draft.status
  end

  # F11
  test "a sister asking to borrow money gets family-support coaching, not a garbled purchase scenario" do
    message = "my sister wants to borrow $300 for her kids school stuff, can we afford that?"
    [ provider_transport(intent: "coaching", resolved: message), ->(_) { nil } ].each_with_index do |transport, index|
      user, household = participant
      complete_setup(household, ready: true)
      with_transport(transport) { post_message(user, message) }
      assert_response :created
      refute_includes reply, "Purchase scenario", "transport #{index}"
      refute_includes reply, "For at"
      refute_includes reply, "all 1"
      assert_includes reply, "family support", "transport #{index}"
    end
  end

  # F12
  test "asking about the Car repair category answers about that category, not a new repair bill" do
    user, household = participant
    complete_setup(household, ready: true)
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    car = manager.create_category!(name: "Car repair", stack_key: "sinking_unexpected", monthly_amount: 100)
    confirmed(household, manager, car, "Tommy's Auto Repair", 64_000, Date.new(2026, 9, 20))

    with_resolved_intent(coaching_intent("Should I raise the Car repair category?")) { post_message(user, "should i raise the car repair category") }
    assert_includes reply, "Car repair is planned at $100"
    assert_includes reply, "$640 confirmed"
    refute_includes reply, "real baseline need"

    with_resolved_intent(coaching_intent("Can we cover a $400 car repair due Friday?")) { post_message(user, "can we cover a $400 car repair due friday") }
    assert_includes reply, "real baseline need"
  end

  # F14
  test "health details are saved as sensitive memory that waits for confirmation" do
    user, household = participant
    post_message(user, "remember that my husband has diabetes and his insulin is about $120 a month")
    memory = household.household_memories.order(:id).last
    assert_equal "sensitive", memory.sensitivity
    assert_equal "pending_confirmation", memory.status
    assert_includes reply, "as sensitive"

    post_message(user, "also remember my husband has diabetes so we spend extra on his meds every month")
    also = household.household_memories.order(:id).last
    assert_equal "my husband has diabetes so we spend extra on his meds every month", also.display_value
    assert_equal "sensitive", also.sensitivity

    post_message(user, "remember that payday is the 15th and 30th")
    assert_equal "ordinary", household.household_memories.order(:id).last.sensitivity
  end

  test "remember only triggers for a whole-message memory command" do
    user, household = participant
    before = household.household_memories.count
    post_message(user, "ok remember that car repair in september? how much was it")
    post_message(user, "so remember we spent $40 at KFC yesterday")
    assert_equal before, household.household_memories.count
    refute_includes reply.to_s, "I will remember"
    post_message(user, "ok remember that payday is the 15th and 30th")
    assert_equal before + 1, household.household_memories.count
  end

  # N5
  test "how much do we owe on the credit card answers from the approved debt summary" do
    user, household = participant
    complete_setup(household)
    household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 320_000, debt_summary_balance_known: true, debt_summary_minimum_payment_cents: 9_500, debt_summary_minimum_payment_known: true)

    post_message(user, "how much do we owe on the credit card")

    assert_response :created
    assert_includes reply, "$3,200.00"
    assert_includes reply, "$95.00"
    assert_includes reply, "not a per-card figure"
    refute_includes reply, "check the annual plan"
  end

  private

  def participant
    user = User.create!(email: "qa-chat-#{SecureRandom.hex(6)}@example.test", clerk_id: "test_#{SecureRandom.hex(6)}", role: "participant", invitation_status: "accepted")
    [ user, HouseholdFinance::WorkspaceResolver.new(user).household ]
  end

  def complete_setup(household, ready: false)
    HouseholdFinance::SetupUpdater.new(household, {
      household_name: "Taitano House", primary_goal: "Pay down the credit card",
      primary_income: "4200", fixed_expenses: "2100", flexible_spend: "800"
    }).call
    HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).plan_data
    return unless ready

    household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 0, debt_summary_balance_known: true,
      debt_summary_minimum_payment_cents: 0, debt_summary_minimum_payment_known: true)
    household.accounts.create!(label: "BOG Checking", account_type: "checking", balance_cents: 185_000, balance_as_of_on: Date.current)
  end

  def confirmed(household, manager, category, merchant, cents, on)
    transaction = household.household_transactions.create!(budget_period: manager.current_period_for(on), occurred_on: on,
      merchant: merchant, total_amount_cents: cents, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: category, amount_cents: cents)
  end

  def expense(source, merchant, amount)
    { source_text: source, depends_on: [], action: blank_action.merge(type: "create_transaction_draft", merchant: merchant, amount: amount, occurred_on: "2026-10-15") }
  end

  def coaching_intent(resolved)
    intent_result("coaching", resolved)
  end

  def report_intent(resolved)
    intent_result("spending_report", resolved)
  end

  def intent_result(intent, resolved)
    HouseholdFinance::MiaIntentResolver::Result.new(
      intent: intent, confidence: 0.95, continuation: true, resolved_message: resolved,
      needs_clarification: false, clarification: "", topic: { type: intent, title: "Spending", subject: "Spending" },
      action: { type: "none" }, read_only_plan: {}, source: "model"
    )
  end

  def with_resolved_intent(result, &block)
    with_resolver_factory(->(**) { Struct.new(:result) { def call = result }.new(result) }, &block)
  end

  def with_provider(intent:, action: {}, write_plan: { title: "", actions: [] }, &block)
    with_transport(provider_transport(intent: intent, action: action, write_plan: write_plan), &block)
  end

  def with_transport(transport, &block)
    original = HouseholdFinance::MiaIntentResolver.method(:new)
    with_resolver_factory(->(**kwargs) { original.call(**kwargs, api_key: "test-key", transport: transport) }, &block)
  end

  def provider_transport(intent:, action: {}, write_plan: { title: "", actions: [] }, resolved: "resolved")
    lambda do |_payload|
      {
        intent: intent, confidence: 0.96, continuation: false, resolved_message: resolved,
        needs_clarification: false, clarification: "", topic: { type: intent, title: "QA", subject: "QA" },
        read_only_plan: { title: "", items: [] }, write_plan: write_plan, action: blank_action.merge(action)
      }.to_json
    end
  end

  def with_resolver_factory(factory)
    singleton = HouseholdFinance::MiaIntentResolver.singleton_class
    singleton.define_method(:new) { |**kwargs| factory.call(**kwargs) }
    yield
  ensure
    singleton.send(:remove_method, :new) if singleton.instance_methods(false).include?(:new)
  end

  def blank_action
    {
      type: "none", category_id: 0, category_name: "", target_category_id: 0, target_category_name: "", new_name: "",
      stack_key: "", amount: "", months: [], year: 0, draft_id: 0, selected_item_ids: [], occurred_on: "", merchant: "",
      all_pending: false, splits: [], setup_updates: {}
    }
  end

  def post_message(user, content)
    post "/api/v1/mia/messages", params: { message: content }, headers: { "Authorization" => "Bearer test_token_#{user.id}" }, as: :json
  end

  def reply
    response.parsed_body.dig("assistant_message", "content").to_s
  end
end
