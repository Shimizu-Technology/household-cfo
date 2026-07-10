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
end
