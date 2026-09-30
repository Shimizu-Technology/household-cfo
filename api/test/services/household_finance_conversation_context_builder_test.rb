require "test_helper"

class HouseholdFinanceConversationContextBuilderTest < ActiveSupport::TestCase
  test "exposes versioned validated action state for future conversation turns" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "conversation-state@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Conversation State Household")
    session = household.chat_sessions.create!(
      user: user,
      title: "Ask Mia",
      active_topic: {
        schema_version: 2,
        id: SecureRandom.uuid,
        type: "budget_edit",
        title: "July Fixed essentials edit",
        subject: "Fixed essentials",
        intent: "budget_action",
        confidence: 0.98,
        status: "pending_review",
        resolved_message: "Set Fixed essentials to $3,000 for July 2026",
        action: {
          type: "set_allocation",
          category_id: 42,
          category_name: "Fixed essentials",
          amount: "3000.00",
          months: [ 7 ],
          year: 2026
        },
        mia_action_draft_id: 99,
        latest_user_context: "Yeah, please do that",
        latest_mia_summary: "The review card is ready."
      }
    )

    context = HouseholdFinance::ConversationContextBuilder.new(session).call
    active = context.fetch(:active_topic)

    assert_equal 2, active.fetch(:schema_version)
    assert_equal "budget_action", active.fetch(:intent)
    assert_equal "pending_review", active.fetch(:status)
    assert_equal 99, active.fetch(:mia_action_draft_id)
    assert_equal "set_allocation", active.dig(:action, :type)
    assert_equal 42, active.dig(:action, :category_id)
    assert_equal [ 7 ], active.dig(:action, :months)
  end

  test "a persona switch keeps participant facts but removes the retired assistant voice" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "persona-continuity@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Persona Continuity Household")
    topic = {
      schema_version: 2,
      id: SecureRandom.uuid,
      type: "car_repair",
      title: "Car repair",
      subject: "work transportation",
      status: "open",
      amount_label: "$640",
      latest_user_context: "I need the car to get to work.",
      latest_mia_summary: "Chelu, protect the island commute first.",
      next_move: "Call the Dededo shop tomorrow.",
      assistant_persona_context_id: "coach_persona_version:101",
      assistant_persona_version_id: 101
    }
    session = household.chat_sessions.create!(
      user: user,
      title: "Ask Mia",
      active_topic: topic,
      open_topics: [ topic ],
      rolling_summary: "Chelu, protect the island commute first."
    )

    context = HouseholdFinance::ConversationContextBuilder.new(
      session,
      persona_context_id: "coach_persona_version:202"
    ).call

    assert_equal "Car repair", context.dig(:active_topic, :title)
    assert_equal "work transportation", context.dig(:active_topic, :subject)
    assert_equal "$640", context.dig(:active_topic, :amount_label)
    assert_equal "I need the car to get to work.", context.dig(:active_topic, :latest_user_context)
    refute context.fetch(:active_topic).key?(:latest_mia_summary)
    refute context.fetch(:active_topic).key?(:next_move)
    assert_includes context.fetch(:rolling_summary), "Car repair"
    assert_includes context.fetch(:rolling_summary), "$640"
    refute_includes context.fetch(:rolling_summary), "Chelu"
    refute_includes context.fetch(:rolling_summary), "Dededo"
  end

  test "continuity keeps assistant context only for the exact active persona version" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "same-persona-continuity@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Same Persona Continuity Household")
    topic = {
      schema_version: 2,
      id: SecureRandom.uuid,
      type: "debt",
      title: "Debt decision",
      subject: "credit card",
      latest_user_context: "I want to pay down the card.",
      latest_mia_summary: "Keep the minimum protected first.",
      next_move: "Confirm the interest rate.",
      assistant_persona_context_id: "coach_persona_version:303",
      assistant_persona_version_id: 303
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: topic, open_topics: [ topic ])

    context = HouseholdFinance::ConversationContextBuilder.new(
      session,
      persona_context_id: "coach_persona_version:303"
    ).call

    assert_equal "Keep the minimum protected first.", context.dig(:active_topic, :latest_mia_summary)
    assert_equal "Confirm the interest rate.", context.dig(:active_topic, :next_move)
  end
end
