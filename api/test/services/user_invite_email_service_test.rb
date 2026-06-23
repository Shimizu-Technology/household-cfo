require "test_helper"

class UserInviteEmailServiceTest < ActiveSupport::TestCase
  test "send invite skips when Resend is not configured" do
    user = create_user(email: "invitee@example.com")
    result = UserInviteEmailService.send_invite(user: user, invited_by: nil)

    assert_equal false, result.fetch(:sent)
    assert_equal "skipped", result.fetch(:status)
    assert_includes result.fetch(:error), "RESEND_API_KEY"
  end

  test "send invite sends through Resend when configured" do
    user = create_user(email: "invitee@example.com", role: "coach")
    invited_by = create_user(email: "admin@example.com", role: "admin")
    payloads = []

    with_env("RESEND_API_KEY" => "re_test", "MAILER_FROM_EMAIL" => "Household CFO <noreply@example.com>", "FRONTEND_URL" => "https://household.example") do
      with_resend_send_stub(->(payload) { payloads << payload; { "id" => "email_123" } }) do
        result = UserInviteEmailService.send_invite(user: user, invited_by: invited_by)

        assert_equal true, result.fetch(:sent)
        assert_equal "sent", result.fetch(:status)
        assert_equal "email_123", result.fetch(:provider_message_id)
      end
    end

    payload = payloads.fetch(0)
    assert_equal "Household CFO <noreply@example.com>", payload.fetch(:from)
    assert_equal "invitee@example.com", payload.fetch(:to)
    assert_includes payload.fetch(:html), "Open Household CFO"
    assert_includes payload.fetch(:html), "invitee@example.com"
    assert_includes payload.fetch(:text), "admin invited you"
  end

  private

  def create_user(email:, role: "participant")
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: role,
      invitation_status: "accepted"
    )
  end

  def with_resend_send_stub(callable)
    original_method = Resend::Emails.method(:send)
    Resend::Emails.define_singleton_method(:send) { |payload| callable.call(payload) }
    yield
  ensure
    Resend::Emails.define_singleton_method(:send, original_method)
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
