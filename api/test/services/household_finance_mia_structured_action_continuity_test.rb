require "test_helper"

class HouseholdFinanceMiaStructuredActionContinuityTest < ActiveSupport::TestCase
  test "a validated clarification survives transcript compaction as structured state" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "structured-compaction-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Structured Continuity Household")
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    original_user = session.chat_messages.create!(role: "user", content: "Set Fixed essentials to $3,000, but ask me which month.")
    original_assistant = session.chat_messages.create!(role: "assistant", content: "Which month should the $3,000 Fixed essentials amount apply to?")
    incomplete_intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "budget_action",
      confidence: 0.98,
      continuation: false,
      resolved_message: "Set Fixed essentials to $3,000 after the participant chooses a month",
      needs_clarification: true,
      clarification: "Which month should this apply to?",
      topic: { type: "budget_edit", title: "Fixed essentials edit", subject: "Fixed essentials" },
      action: {
        type: "set_allocation",
        category_id: 42,
        category_name: "Fixed essentials",
        amount: "3000",
        months: [],
        year: 2026
      },
      read_only_plan: {},
      source: "model"
    )

    assert HouseholdFinance::MiaConversationStateUpdater.new(
      session,
      intent_result: incomplete_intent,
      user_message: original_user,
      assistant_message: original_assistant
    ).call

    82.times do |index|
      session.chat_messages.create!(role: index.even? ? "user" : "assistant", content: "Unrelated compacted turn #{index + 1}")
    end
    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(session).call
    refute transcript.any? { |message| message.fetch(:content).include?("$3,000") }

    continuity = HouseholdFinance::ConversationContextBuilder.new(session.reload).call
    context = {
      budget_view_period: { year: 2026, month: 8, label: "Aug 2026" },
      conversation: {
        active_thread: continuity.fetch(:active_topic),
        open_threads: continuity.fetch(:open_topics),
        older_summary: continuity.fetch(:rolling_summary),
        recent_messages: transcript
      },
      budget_categories: [ { id: 42, name: "Fixed essentials", stack_key: "non_discretionary" } ],
      archived_categories: [],
      pending_budget_reviews: [],
      pending_transaction_reviews: [],
      approved_household_setup: {},
      income_sources: []
    }
    resolver = HouseholdFinance::MiaIntentResolver.new(
      user_message: "August only.",
      context: context,
      api_key: "test-key",
      transport: lambda do |_payload|
        {
          intent: "budget_action",
          confidence: 0.98,
          continuation: true,
          resolved_message: "Set Fixed essentials to $3,000 for August 2026",
          needs_clarification: false,
          clarification: "",
          topic: { type: "budget_edit", title: "Fixed essentials edit", subject: "Fixed essentials" },
          read_only_plan: { title: "", items: [] },
          action: default_action.merge(type: "set_allocation", months: [ 8 ])
        }.to_json
      end
    )

    result = resolver.call

    assert result.actionable?
    assert_equal "3000", result.action.fetch(:amount)
    assert_equal [ 8 ], result.action.fetch(:months)
    assert_equal 42, result.action.fetch(:category_id)
  end

  private

  def default_action
    {
      type: "none",
      category_id: 0,
      category_name: "",
      target_category_id: 0,
      target_category_name: "",
      new_name: "",
      stack_key: "",
      amount: "",
      months: [],
      year: 0,
      draft_id: 0,
      occurred_on: "",
      merchant: "",
      all_pending: false,
      splits: [],
      setup_updates: {
        household_name: "",
        primary_goal: "",
        primary_income: "",
        business_income: "",
        fixed_expenses: "",
        flexible_spend: "",
        expected_sinking_fund: "",
        unexpected_sinking_fund: "",
        emergency_fund: "",
        other_assets: "",
        credit_card_debt: "",
        debt_payment: "",
        target_runway_months: ""
      },
      income_source_id: 0,
      income_source_name: "",
      entry_type: "",
      effective_on: "",
      schedule_label: ""
    }
  end
end
