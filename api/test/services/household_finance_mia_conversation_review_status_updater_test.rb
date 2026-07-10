require "test_helper"

class HouseholdFinanceMiaConversationReviewStatusUpdaterTest < ActiveSupport::TestCase
  test "updates matching review lifecycle state without changing unrelated threads" do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "review-state@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Review State Household")
    active = {
      id: "budget-thread",
      type: "budget_edit",
      title: "July budget edit",
      subject: "Fixed essentials",
      status: "pending_review",
      mia_action_draft_id: 91,
      latest_mia_summary: "Waiting for review."
    }
    unrelated = {
      id: "readiness-thread",
      type: "readiness_plan",
      title: "Readiness plan",
      subject: "runway",
      status: "open"
    }
    session = household.chat_sessions.create!(user: user, title: "Ask Mia", active_topic: active, open_topics: [ active, unrelated ])

    result = HouseholdFinance::MiaConversationReviewStatusUpdater.new(
      session,
      reference_key: "mia_action_draft_id",
      reference_id: 91,
      status: "applied",
      summary: "Applied the July Fixed essentials edit."
    ).call

    assert result
    session.reload
    assert_equal "applied", session.active_topic.fetch("status")
    assert_equal "applied", session.open_topics.first.fetch("status")
    assert_equal "open", session.open_topics.second.fetch("status")
    assert_includes session.rolling_summary, "applied"
    assert_includes session.rolling_summary, "Readiness plan"
  end
end
