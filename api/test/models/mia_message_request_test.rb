require "test_helper"

class MiaMessageRequestTest < ActiveSupport::TestCase
  setup do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "mia-request-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Request household")
    @session = household.chat_sessions.create!(user: user, title: "Ask Mia")
  end

  test "request keys are unique inside a chat session" do
    @session.mia_message_requests.create!(request_key: "request-1", request_fingerprint: "a" * 64)
    duplicate = @session.mia_message_requests.build(request_key: "request-1", request_fingerprint: "b" * 64)

    refute duplicate.valid?
    assert_includes duplicate.errors[:request_key], "has already been taken"
  end

  test "completion stores an immutable replay payload and status" do
    request = @session.mia_message_requests.create!(request_key: "request-2", request_fingerprint: "a" * 64)

    request.complete!({ "assistant_message" => { "content" => "Verified answer" } }, response_status: 201)

    assert request.completed?
    assert_equal 201, request.response_status
    assert_equal "Verified answer", request.response_payload.dig("assistant_message", "content")
    assert request.completed_at.present?
  end

  test "request keys reject unsafe or oversized values" do
    unsafe = @session.mia_message_requests.build(request_key: "spaces are unsafe", request_fingerprint: "a" * 64)
    oversized = @session.mia_message_requests.build(request_key: "a" * 101, request_fingerprint: "a" * 64)

    refute unsafe.valid?
    refute oversized.valid?
  end
end
