require "test_helper"
require_relative "../support/authentication_transition_test_support"

class AuthenticationTransitionInvitationTest < ActiveSupport::TestCase
  include AuthenticationTransitionTestSupport

  setup do
    @owner = User.create!(email: "owner@fictional.test", clerk_id: "clerk_owner", role: "coach", invitation_status: "accepted")
    @workspace = CoachWorkspaces::Provisioner.ensure_for!(@owner)
    @invitee = User.create!(email: "invitee@fictional.test", clerk_id: "pending_invitee", role: "coach", invitation_status: "pending")
  end

  test "Clerk public frontend routes both mailers through existing Resend delivery" do
    with_transition("AUTH_PUBLIC_PROVIDER" => "clerk") do
      configure_resend
      emails = []
      stub_method(WorkosInvitationService, :send_invite, ->(**) { flunk "Public Clerk invitation reached WorkOS" }) do
        stub_method(Resend::Emails, :send, ->(payload) { emails << payload; { "id" => "email_accepted" } }) do
          participant = UserInviteEmailService.send_invite(user: @invitee, invited_by: @owner)
          collaborator = send_collaborator
          assert participant.fetch(:sent)
          assert collaborator.fetch(:sent)
          assert_equal "resend", participant.fetch(:provider)
          assert_equal "resend", collaborator.fetch(:provider)
          assert_equal "resend", @invitee.invitation_email_attempts.last.provider
          assert_equal [ @invitee.email, @invitee.email ], emails.map { |email| email.fetch(:to) }
          assert_equal "pending", @invitee.reload.invitation_status
        end
      end
    end
  end

  test "WorkOS public frontend routes pending registrations once through native invitations" do
    with_transition("AUTH_PUBLIC_PROVIDER" => "workos") do
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

  test "accepted collaborators retain Resend access notifications under public WorkOS" do
    with_transition("AUTH_PUBLIC_PROVIDER" => "workos") do
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

  test "missing and unknown public providers visibly fail both mailers without sending" do
    [ nil, "unknown", "transition" ].each do |provider|
      with_transition("AUTH_PUBLIC_PROVIDER" => provider) do
        stub_method(Resend::Emails, :send, ->(*) { flunk "Unconfigured invitation reached Resend" }) do
          stub_method(WorkosInvitationService, :send_invite, ->(**) { flunk "Unconfigured invitation reached WorkOS" }) do
            [ UserInviteEmailService.send_invite(user: @invitee, invited_by: @owner), send_collaborator ].each do |result|
              refute result.fetch(:sent)
              assert_equal "failed", result.fetch(:status)
              assert_equal "unconfigured", result.fetch(:provider)
              assert_includes result.fetch(:error), "Public authentication provider"
            end
            attempt = @invitee.invitation_email_attempts.last
            assert_equal "failed", attempt.status
            assert_equal "unconfigured", attempt.provider
            assert_includes attempt.error, "Public authentication provider"
          end
        end
      end
    end
  end

  test "skipped collaborator delivery stays skipped without public configuration" do
    with_transition("AUTH_PUBLIC_PROVIDER" => nil) do
      result = send_collaborator(requested: false)
      assert_equal "skipped", result.fetch(:status)
      assert_equal "skipped", @invitee.invitation_email_attempts.last.status
    end
  end

  test "strict provider modes remain authoritative after transition retirement" do
    with_transition("AUTH_PROVIDER" => "workos", "AUTH_PUBLIC_PROVIDER" => "clerk") do
      assert_equal "workos", AuthenticationProvider.public_provider
    end
    with_transition("AUTH_PROVIDER" => "clerk", "AUTH_PUBLIC_PROVIDER" => "workos") do
      assert_equal "clerk", AuthenticationProvider.public_provider
      refute AuthenticationProvider.workos_enabled?
    end
  end

  private

  def configure_resend
    ENV["RESEND_API_KEY"] = "test-key"
    ENV["MAILER_FROM_EMAIL"] = "Household CFO <noreply@fictional.test>"
  end

  def send_collaborator(requested: true)
    CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: @invitee, workspace: @workspace, role: "reviewer", invited_by: @owner,
      sign_in_url: "https://householdcfomethod.com/workspace", requested: requested)
  end
end
