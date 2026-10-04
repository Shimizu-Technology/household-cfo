require "test_helper"

class CoachWorkspaceCollaboratorInviteEmailTest < ActiveSupport::TestCase
  test "access email names the exact workspace role and sign in link and needs provider acceptance" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.test", clerk_id: "owner_#{SecureRandom.hex(4)}", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    invitee = User.create!(email: "invitee-#{SecureRandom.hex(4)}@example.test", clerk_id: "pending_#{SecureRandom.hex(4)}", role: "coach")
    original_environment = %w[RESEND_API_KEY RESEND_FROM_EMAIL MAILER_FROM_EMAIL].to_h { |key| [ key, ENV[key] ] }
    ENV.delete("RESEND_FROM_EMAIL")
    ENV["RESEND_API_KEY"] = "test-key"
    ENV["MAILER_FROM_EMAIL"] = "coaching@example.test"
    original = Resend::Emails.method(:send)
    payloads = []
    Resend::Emails.define_singleton_method(:send) { |payload| payloads << payload; { "id" => "provider-accepted" } }
    result = CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: invitee, workspace: workspace, role: "reviewer", invited_by: owner, sign_in_url: "https://island.example.test", requested: true)
    assert_equal "sent", result[:status]
    assert_includes payloads.first[:text], workspace.name
    assert_includes payloads.first[:text], "as reviewer"
    assert_includes payloads.first[:text], "https://island.example.test"
    assert_equal "sent", invitee.invitation_email_attempts.last.status
    Resend::Emails.define_singleton_method(:send) { |_payload| { "error" => "rate limited" } }
    result = CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: invitee, workspace: workspace, role: "reviewer", invited_by: owner, sign_in_url: "https://island.example.test", requested: true)
    assert_equal "failed", result[:status]
    assert_equal false, result[:sent]
    assert_equal "failed", invitee.invitation_email_attempts.last.status
  ensure
    Resend::Emails.define_singleton_method(:send, original) if original
    original_environment&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
