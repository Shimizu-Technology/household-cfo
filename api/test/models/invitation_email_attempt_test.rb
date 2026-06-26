require "test_helper"

class InvitationEmailAttemptTest < ActiveSupport::TestCase
  test "validates sent attempts have sent_at" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "attempt-user@example.com",
      role: "participant",
      invitation_status: "accepted"
    )

    attempt = user.invitation_email_attempts.build(
      status: "sent",
      provider: "resend",
      attempted_at: Time.current
    )

    assert_not attempt.valid?
    assert_includes attempt.errors[:sent_at], "is required when status is sent"
  end
end
