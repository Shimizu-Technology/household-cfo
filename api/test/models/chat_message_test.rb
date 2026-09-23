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
    message = @session.chat_messages.new(role: "assistant", content: "a" * 8_000)

    assert message.valid?
    message.content = "a" * 8_001
    assert_not message.valid?
  end
end
