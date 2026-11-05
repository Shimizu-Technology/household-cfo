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

  test "coach-name lookup completes once before any provider invitation mutation" do
    user = create_user(email: "lookup@example.test")
    original_selector = InvitationCoachName.method(:for)
    original_provider = WorkosInvitationService.method(:send_invite)
    events = []
    InvitationCoachName.define_singleton_method(:for) { |**_| events << :name; "Mrs. Mel" }
    WorkosInvitationService.define_singleton_method(:send_invite) { |**_| events << :provider; { sent: true } }
    UserInviteEmailService.send_invite(user: user, invited_by: nil)
    assert_equal [ :name, :provider ], events
  ensure
    InvitationCoachName.define_singleton_method(:for, original_selector) if original_selector
    WorkosInvitationService.define_singleton_method(:send_invite, original_provider) if original_provider
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
  test "cohort workspace inference multiple-workspace fallback personal name and no inviter" do
    coach = User.create!(clerk_id: "selector-coach", email: "selector-coach@example.test", first_name: "Mel", last_name: "Mendiola", role: "coach", invitation_status: "accepted")
    other = User.create!(clerk_id: "selector-other", email: "selector-other@example.test", role: "coach", invitation_status: "accepted")
    recipient = User.create!(clerk_id: "selector-recipient", email: "selector-recipient@example.test")
    own = CoachWorkspaces::Provisioner.ensure_for!(coach)
    target = CoachWorkspaces::Provisioner.ensure_for!(other)
    own.coach_profile.update!(display_name: "Own coaching")
    target.coach_profile.update!(display_name: "Target coaching")
    first = Cohort.create!(name: "Target group", created_by_user: other, coach_workspace: target)
    recipient.cohort_memberships.create!(cohort: first, role: "participant")
    assert_equal "Target coaching", InvitationCoachName.for(user: recipient, invited_by: coach)
    second = Cohort.create!(name: "Own group", created_by_user: coach, coach_workspace: own)
    recipient.cohort_memberships.create!(cohort: second, role: "participant")
    assert_equal "Own coaching", InvitationCoachName.for(user: recipient, invited_by: coach)
    own.coach_profile.update!(display_name: coach.email)
    assert_equal "Mel Mendiola", InvitationCoachName.for(user: recipient, invited_by: coach)
    assert_equal "Your coaching team", InvitationCoachName.for(user: recipient, invited_by: nil)
  end

  test "uses explicit coach display name and never falls back to an email alias" do
    coach = User.create!(clerk_id: "name_coach", email: "shimizu+qa@example.test", role: "coach", invitation_status: "accepted")
    recipient = User.create!(clerk_id: "name_recipient", email: "recipient@example.test")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(coach)
    workspace.coach_profile.update!(display_name: "Mrs. Mel")
    assert_equal "Mrs. Mel", InvitationCoachName.for(user: recipient, invited_by: coach)
    workspace.coach_profile.update!(display_name: coach.email)
    assert_equal "Your coaching team", InvitationCoachName.for(user: recipient, invited_by: coach)
    workspace.coach_profile.update!(display_name: "shimizu")
    assert_equal "Your coaching team", InvitationCoachName.for(user: recipient, invited_by: coach)
    workspace.coach_profile.update!(display_name: "shimizu+qa")
    assert_equal "Your coaching team", InvitationCoachName.for(user: recipient, invited_by: coach)
  end
end
