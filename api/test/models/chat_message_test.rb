require "test_helper"

class ChatMessageTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "chat-length-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Chat length household")
    @session = household.chat_sessions.create!(user: user, title: "Ask Mia")
  end

  test "accepts exactly two thousand Unicode characters from a participant" do
    message = @session.chat_messages.new(role: "user", content: "å" * 2_000)

    assert message.valid?
  end

  test "rejects more than two thousand participant characters" do
    message = @session.chat_messages.new(role: "user", content: "å" * 2_001)

    assert_not message.valid?
    assert_includes message.errors.full_messages, "Content is too long (maximum is 2000 characters)"
  end

  test "allows a bounded assistant response longer than the participant limit" do
    message = @session.chat_messages.create!(role: "assistant", content: "a" * 8_000)

    assert message.persisted?
    assert_raises(ActiveRecord::StatementInvalid) do
      @session.chat_messages.insert_all!([ { role: "assistant", content: "a" * 8_001, created_at: Time.current, updated_at: Time.current } ])
    end
  end

  test "persists and serializes a bounded read-only presentation" do
    presentation = {
      version: 1,
      kind: "read_only_answer",
      basis: "saved_household_plus_scenario",
      lead: "Two answers.",
      sections: [ { id: "part-1", title: "Readiness", body: "Saved household answer." } ],
      scenario: { values: [ { label: "Laptop", display_value: "$900" } ] }
    }

    message = @session.chat_messages.create!(role: "assistant", content: "1. Readiness\nSaved household answer.", presentation: presentation)

    assert_equal 1, message.as_api_json.dig(:presentation, "version")
    assert_equal "$900", message.as_api_json.dig(:presentation, "scenario", "values", 0, "display_value")
  end

  test "rejects a presentation whose hidden serialized payload exceeds the assistant content limit" do
    presentation = {
      version: 1,
      kind: "read_only_answer",
      basis: "saved_household",
      lead: "Answers",
      sections: (1..5).map { |number| { id: "part-#{number}", title: "Part #{number}", body: "a" * 1_700 } }
    }
    message = @session.chat_messages.new(role: "assistant", content: "Short canonical answer", presentation: presentation)

    refute message.valid?
    assert_includes message.errors.full_messages, "Presentation is not a supported Mia presentation"
  end

  test "database rejects a non-object presentation when model validation is bypassed" do
    assert_raises(ActiveRecord::StatementInvalid) do
      @session.chat_messages.insert_all!([ {
        role: "assistant",
        content: "Bounded answer",
        presentation: [],
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  test "rejects unknown presentation fields" do
    message = @session.chat_messages.new(
      role: "assistant",
      content: "1. Readiness\nSaved household answer.",
      presentation: {
        version: 1,
        kind: "read_only_answer",
        basis: "saved_household",
        lead: "One answer.",
        sections: [ { id: "part-1", title: "Readiness", body: "Saved household answer." } ],
        internal_context: "must not be persisted"
      }
    )

    refute message.valid?
    assert_includes message.errors.full_messages, "Presentation is not a supported Mia presentation"
  end
end
