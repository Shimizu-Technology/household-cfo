require "test_helper"

class UserInviteEmailServiceTest < ActiveSupport::TestCase
  test "send invite fails clearly when sign-in is not configured" do
    user = create_user(email: "invitee@example.com")
    result = with_resend_send_stub(->(*) { flunk "Unconfigured invitation reached Resend" }) do
      UserInviteEmailService.send_invite(user: user, invited_by: nil)
    end

    assert_equal false, result.fetch(:sent)
    assert_equal "failed", result.fetch(:status)
    assert_equal "workos", result.fetch(:provider)
    assert_includes result.fetch(:error), "WorkOS authentication is not configured"
  end

  test "custom delivery fails clearly before contacting WorkOS when Resend is not configured" do
    user = create_user(email: "invitee@example.com")
    result = with_env("WORKOS_CLIENT_ID" => "client_cfo", "WORKOS_API_KEY" => "test-secret", "WORKOS_INVITATION_EMAIL_DELIVERY" => "custom") do
      UserInviteEmailService.send_invite(user: user, invited_by: nil)
    end

    assert_equal false, result.fetch(:sent)
    assert_equal "failed", result.fetch(:status)
    assert_includes result.fetch(:error), "RESEND_API_KEY"
  end

  # Branded custom delivery content is covered end to end in WorkosInvitationServiceTest.

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

class InvitationCoachNameTest < ActiveSupport::TestCase
  test 'uses explicit coach display name and never falls back to an email alias' do
    coach = User.create!(clerk_id: 'name_coach', email: 'shimizu+qa@example.test', role: 'coach', invitation_status: 'accepted')
    recipient = User.create!(clerk_id: 'name_recipient', email: 'recipient@example.test')
    workspace = CoachWorkspaces::Provisioner.ensure_for!(coach)
    workspace.coach_profile.update!(display_name: 'Mrs. Mel')
    assert_equal 'Mrs. Mel', InvitationCoachName.for(user: recipient, invited_by: coach)
    workspace.coach_profile.update!(display_name: coach.email)
    assert_equal 'Your coaching team', InvitationCoachName.for(user: recipient, invited_by: coach)
    workspace.coach_profile.update!(display_name: 'shimizu+qa')
    assert_equal 'Your coaching team', InvitationCoachName.for(user: recipient, invited_by: coach)
  end
end
