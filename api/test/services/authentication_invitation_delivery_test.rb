require "test_helper"
require_relative "../support/workos_auth_test_support"

class AuthenticationInvitationDeliveryTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  setup do
    @owner = User.create!(email: "owner@fictional.test", clerk_id: "clerk_owner", role: "coach", invitation_status: "accepted")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @invitee = User.create!(email: "invitee@fictional.test", clerk_id: "pending_invitee", role: "coach", invitation_status: "pending")
  end

  test "pending registrations go once through native WorkOS invitations" do
    with_delivery do
      invitations = []
      native = lambda do |**options|
        invitations << options
        { sent: true, status: "sent", provider: "workos", provider_message_id: "invitation_test", error: nil }
      end
      stub_method(Resend::Emails, :send, ->(*) { flunk "Native invitation sent a duplicate Resend email" }) do
        stub_method(WorkosInvitationService, :send_invite, native) do
          participant = UserInviteEmailService.send_invite(user: @invitee, invited_by: @owner)
          collaborator = send_collaborator
          assert_equal "workos", participant.fetch(:provider)
          assert_equal "workos", collaborator.fetch(:provider)
          assert_equal "workos", @invitee.invitation_email_attempts.last.provider
          assert_equal [ @invitee.id, @invitee.id ], invitations.map { |options| options.fetch(:user).id }
          assert_equal "pending", @invitee.reload.invitation_status
        end
      end
    end
  end

  test "accepted collaborators keep Resend access notifications" do
    with_delivery do
      configure_resend
      @invitee.update!(invitation_status: "accepted")
      payloads = []
      stub_method(WorkosInvitationService, :send_invite, ->(**) { flunk "Accepted collaborator received a registration invitation" }) do
        stub_method(Resend::Emails, :send, ->(payload) { payloads << payload; { "id" => "email_notification" } }) do
          result = send_collaborator
          assert result.fetch(:sent)
          assert_equal "resend", result.fetch(:provider)
          assert_equal "resend", @invitee.invitation_email_attempts.last.provider
          assert_equal 1, payloads.size
          assert_includes payloads.sole.fetch(:text), "https://householdcfomethod.com/workspace"
          assert_equal "accepted", @invitee.reload.invitation_status
        end
      end
    end
  end

  test "a stale non-WorkOS provider setting visibly fails both mailers without sending" do
    [ "clerk", "transition", "unknown" ].each do |provider|
      with_delivery("AUTH_PROVIDER" => provider) do
        stub_method(Resend::Emails, :send, ->(*) { flunk "Unconfigured invitation reached Resend" }) do
          stub_method(WorkosInvitationService, :send_invite, ->(**) { flunk "Unconfigured invitation reached WorkOS" }) do
            [ UserInviteEmailService.send_invite(user: @invitee, invited_by: @owner), send_collaborator ].each do |result|
              refute result.fetch(:sent)
              assert_equal "failed", result.fetch(:status)
              assert_equal "unconfigured", result.fetch(:provider)
              assert_includes result.fetch(:error), "Authentication provider is not configured"
            end
            attempt = @invitee.invitation_email_attempts.last
            assert_equal "failed", attempt.status
            assert_equal "unconfigured", attempt.provider
          end
        end
      end
    end
  end

  test "skipped collaborator delivery stays skipped even with a stale provider setting" do
    with_delivery("AUTH_PROVIDER" => "clerk") do
      result = send_collaborator(requested: false)
      assert_equal "skipped", result.fetch(:status)
      assert_equal "skipped", @invitee.invitation_email_attempts.last.status
    end
  end

  test "WorkOS is the only provider and an omitted setting selects it" do
    with_delivery("AUTH_PROVIDER" => nil) do
      assert_equal "workos", AuthenticationProvider.public_provider
      assert AuthenticationProvider.workos_enabled?
    end
    with_delivery("AUTH_PROVIDER" => "clerk") do
      assert_raises(AuthenticationProvider::ConfigurationError) { AuthenticationProvider.public_provider }
      assert_raises(AuthenticationProvider::ConfigurationError) { AuthenticationProvider.workos_enabled? }
    end
  end

  private

  def with_delivery(values = {}, &block)
    keys = %w[RESEND_API_KEY MAILER_FROM_EMAIL]
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    with_workos(values, &block)
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def configure_resend
    ENV["RESEND_API_KEY"] = "test-key"
    ENV["MAILER_FROM_EMAIL"] = "Household CFO <noreply@fictional.test>"
  end

  def send_collaborator(requested: true)
    CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: @invitee, workspace: @workspace, role: "reviewer", invited_by: @owner,
      sign_in_url: "https://householdcfomethod.com/workspace", requested: requested)
  end
end
