require "test_helper"
require_relative "../support/savings_challenge_test_support"
require Rails.root.join("db/migrate/20261004320000_scope_challenge_chat_sessions").to_s

class ScopeChallengeChatSessionsTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    with_savings_runtime { }
  end

  test "upgrade retains proven program message IDs and replay but does not invent attribution for mixed state" do
    legacy = ChatSession.create!(household: @savings_household, user: @savings_user,
      rolling_summary: "Mixed old summary", active_topic: { "summary" => "Mixed evidence" })
    old_message = legacy.chat_messages.create!(role: "user", content: "Unattributed legacy message")
    attributed_user = legacy.chat_messages.create!(role: "user", content: "Attributed synthetic question",
      cohort: @savings_cohort, cohort_release: @savings_release)
    attributed_assistant = legacy.chat_messages.create!(role: "assistant", content: "Attributed synthetic answer",
      cohort: @savings_cohort, cohort_release: @savings_release)
    safe_request = legacy.mia_message_requests.create!(request_key: "proven-completed", request_fingerprint: "a" * 64,
      status: "completed", response_payload: { user_message: attributed_user.as_api_json, assistant_message: attributed_assistant.as_api_json, budget: nil })
    ambiguous = legacy.mia_message_requests.create!(request_key: "ambiguous", request_fingerprint: "b" * 64,
      status: "completed", response_payload: { budget: { private: "Mixed old budget" } })
    processing = legacy.mia_message_requests.create!(request_key: "processing", request_fingerprint: "c" * 64)
    # Test the exact upgrade SQL within this test's rollback-only DDL transaction.
    ApplicationRecord.connection.execute("DROP TRIGGER chat_messages_scope ON chat_messages")
    ScopeChallengeChatSessions.new.backfill_attributed_history
    scope = @savings_household.chat_sessions.find_by!(user: @savings_user, cohort: @savings_cohort)
    assert_equal [ attributed_user.id, attributed_assistant.id ], scope.chat_messages.order(:id).pluck(:id)
    assert_equal legacy.id, old_message.reload.chat_session_id
    assert_equal scope.id, safe_request.reload.chat_session_id
    assert_equal legacy.id, ambiguous.reload.chat_session_id
    assert_equal legacy.id, processing.reload.chat_session_id
    assert_nil scope.rolling_summary
    assert_equal({}, scope.active_topic)
    assert_equal "Mixed old summary", legacy.reload.rolling_summary
    assert_equal({ "summary" => "Mixed evidence" }, legacy.active_topic)
    # Backfill is idempotent and keeps the original legacy session ID.
    ScopeChallengeChatSessions.new.backfill_attributed_history
    assert_equal 2, @savings_household.chat_sessions.count
    assert_equal legacy.id, @savings_household.chat_sessions.find_by!(cohort_id: nil).id
  end

  test "message and session program bindings reject direct SQL cross-program writes" do
    scope = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    message = scope.chat_messages.new(role: "user", content: "Missing sealed binding")
    refute message.valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        ChatMessage.insert_all!([ { chat_session_id: scope.id, role: "user", content: "Missing binding", created_at: Time.current, updated_at: Time.current } ])
      end
    end
    message = scope.chat_messages.create!(role: "user", content: "Bound synthetic question", cohort: @savings_cohort, cohort_release: @savings_release)
    legacy = ChatSession.create!(household: @savings_household, user: @savings_user)
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { message.update_columns(chat_session_id: legacy.id) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { scope.update_columns(cohort_id: nil) }
    end
    other_release = CohortReleases::Sealer.new(cohort: @savings_cohort, actor: nil, publication_source: "system").call!(request_key: "other-valid-savings-seal")
    refute_equal @savings_release.id, other_release.id
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { message.update_columns(cohort_release_id: other_release.id) }
    end
  end

  test "rollback refuses to merge program requests and state into legacy history" do
    assert_raises(ActiveRecord::IrreversibleMigration) { ScopeChallengeChatSessions.new.down }
  end
end
