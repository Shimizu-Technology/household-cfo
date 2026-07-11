require "test_helper"

class HouseholdFinanceMiaConversationStateUpdaterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "state-updater-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "State Updater Household")
    @session = @household.chat_sessions.create!(
      user: @user,
      title: "Ask Mia",
      active_topic: { id: "old", type: "readiness_plan", title: "Readiness plan", subject: "runway", status: "open" },
      open_topics: [ { id: "old", type: "readiness_plan", title: "Readiness plan", subject: "runway", status: "open" } ]
    )
  end

  test "a new unrelated model turn does not leave a stale thread active" do
    user_message = @session.chat_messages.create!(role: "user", content: "Tell me something unrelated")
    assistant_message = @session.chat_messages.create!(role: "assistant", content: "What would you like to work through?")
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "general",
      confidence: 0.9,
      continuation: false,
      resolved_message: "Tell me something unrelated",
      needs_clarification: false,
      clarification: "",
      topic: { type: "", title: "", subject: "" },
      action: { type: "none" },
      source: "model"
    )

    HouseholdFinance::MiaConversationStateUpdater.new(
      @session,
      intent_result: intent,
      user_message: user_message,
      assistant_message: assistant_message
    ).call

    assert_empty @session.reload.active_topic
    assert_equal "readiness_plan", @session.open_topics.first.fetch("type")
  end

  test "recall creates a validated thread when legacy topics do not match the corrected subject" do
    user_message = @session.chat_messages.create!(role: "user", content: "What were we just talking about?")
    assistant_message = @session.chat_messages.create!(role: "assistant", content: "The Fixed essentials adjustment.")
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "recall",
      confidence: 1.0,
      continuation: false,
      resolved_message: "Recall the unresolved Fixed essentials adjustment",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "July Fixed essentials edit", subject: "Fixed essentials" },
      action: { type: "set_allocation", category_id: 42, category_name: "Fixed essentials", amount: "3000", months: [ 7 ], year: 2026 },
      source: "model"
    )

    HouseholdFinance::MiaConversationStateUpdater.new(
      @session,
      intent_result: intent,
      user_message: user_message,
      assistant_message: assistant_message
    ).call

    active = @session.reload.active_topic
    assert_equal 2, active.fetch("schema_version")
    assert_equal "budget_edit", active.fetch("type")
    assert_equal "Fixed essentials", active.fetch("subject")
    assert_equal "set_allocation", active.fetch("action").fetch("type")
    assert_equal [ 7 ], active.fetch("action").fetch("months")
    refute_equal "old", active.fetch("id")
  end

  test "recall promotes the model-selected recent thread instead of a stale active thread" do
    budget_topic = { id: "budget", type: "budget_edit", title: "July budget edit", subject: "Fixed essentials", status: "open" }
    @session.update!(open_topics: [ budget_topic, @session.active_topic ])
    user_message = @session.chat_messages.create!(role: "user", content: "What were we just talking about?")
    assistant_message = @session.chat_messages.create!(role: "assistant", content: "The July Fixed essentials edit.")
    intent = HouseholdFinance::MiaIntentResolver::Result.new(
      intent: "recall",
      confidence: 0.99,
      continuation: false,
      resolved_message: "Recall the July budget edit",
      needs_clarification: false,
      clarification: "",
      topic: { type: "budget_edit", title: "July budget edit", subject: "Fixed essentials" },
      action: { type: "none" },
      source: "model"
    )

    HouseholdFinance::MiaConversationStateUpdater.new(
      @session,
      intent_result: intent,
      user_message: user_message,
      assistant_message: assistant_message
    ).call

    assert_equal "budget", @session.reload.active_topic.fetch("id")
    assert_equal "Fixed essentials", @session.active_topic.fetch("subject")
  end
end
