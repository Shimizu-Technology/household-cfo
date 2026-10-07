require "test_helper"
require_relative "../support/workos_auth_test_support"

class WorkosInvitationServiceTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  setup do
    @invitee = User.create!(clerk_id: "pending_native", email: "native@example.test", role: "coach", invitation_status: "pending")
    @inviter = User.create!(clerk_id: "clerk_inviter", email: "inviter@example.test", role: "admin")
    @requests = []
  end

  test "WorkOS creates one native registration email without Resend and preserves local authority" do
    with_workos do
      @inviter.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_inviter")
      @invitee.update!(invited_by_user: @inviter)
      with_http([], invitation) do
        stub_method(Resend::Emails, :send, ->(*) { flunk "Native invitation must not send a second Resend email" }) do
          result = UserInviteEmailService.send_invite(user: @invitee, invited_by: @inviter)
          assert result[:sent]
          assert_equal "workos", result[:provider]
          assert_equal "invitation_native", result[:provider_message_id]
          refute_includes result.values, "opaque-invitation-token"
          assert_equal "pending", @invitee.reload.invitation_status
          assert_equal "coach", @invitee.role
          assert_equal @inviter.id, @invitee.invited_by_user_id
        end
      end
      posts = @requests.select { |method, _url, _options| method == :post }
      assert_equal 1, posts.length
      payload = JSON.parse(posts.first.last.fetch(:body))
      assert_equal({ "email" => @invitee.email, "inviter_user_id" => "user_inviter" }, payload)
      refute payload.key?("organization_id")
      refute payload.key?("role_slug")
      assert_equal false, posts.first.last[:follow_redirects]
      assert_equal 5, posts.first.last[:timeout]
    end
  end

  test "pending existing invitation is resent rather than duplicated including recorded provider ID" do
    with_workos do
      @invitee.update!(invitation_email_provider_id: "invitation_native")
      with_http([ invitation ], invitation) do
        result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)
        assert result[:sent]
        assert_equal "invitation_native", result[:provider_message_id]
      end
      assert_equal "https://api.workos.com/user_management/invitations/invitation_native", @requests.first[1]
      assert_equal [ "https://api.workos.com/user_management/invitations/invitation_native/resend" ], @requests.filter_map { |method, url, _| url if method == :post }
    end
  end

  test "exact email application invitation lookup ignores other recipients and enterprise invitations" do
    with_workos do
      rows = [ invitation.merge("id" => "invitation_other", "email" => "other@example.test"),
        invitation.merge("id" => "invitation_enterprise", "organization_id" => "org_enterprise"), invitation ]
      with_http(rows, invitation) do
        assert WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)[:sent]
      end
      assert_equal @invitee.email, @requests.first.last.fetch(:query).fetch(:email)
      assert @requests.last[1].end_with?("/invitation_native/resend")
    end
  end

  test "duplicate creation conflict recovers only a matching pending invitation" do
    with_workos do
      reads = 0
      stub_method(HTTParty, :get, lambda { |_url, **_options|
        reads += 1
        WorkosResponse.new(200, { "data" => reads == 1 ? [] : [ invitation ], "list_metadata" => {} })
      }) do
        urls = []
        stub_method(HTTParty, :post, lambda { |url, **_options|
          urls << url
          WorkosResponse.new(url.end_with?("/resend") ? 200 : 409, invitation)
        }) do
          assert WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)[:sent]
          assert_equal 2, urls.length
          assert urls.last.end_with?("/invitation_native/resend")
        end
      end
    end
  end

  test "missing provider configuration 429 outage and invalid response cannot report success" do
    with_workos("WORKOS_API_KEY" => nil) do
      result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)
      refute result[:sent]
      assert_includes result[:error], "not configured"
    end
    with_workos do
      with_http([], {}, code: 429) do
        result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)
        refute result[:sent]
        assert_includes result[:error], "rate limited"
      end
      with_http([], { "id" => "invitation_native" }) do
        refute WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)[:sent]
      end
      stub_method(HTTParty, :get, ->(*_args, **_options) { raise EOFError }) do
        result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)
        refute result[:sent]
        refute_includes result[:error], "test-secret"
      end
    end
  end

  test "native registration invitation never changes or emails accepted revoked local accounts" do
    with_workos do
      %w[accepted revoked].each do |status|
        @invitee.update!(invitation_status: status)
        result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter)
        refute result[:sent]
        assert_includes result[:error], "pending local"
      end
      assert_empty @requests
    end
  end

  test "pending WorkOS collaborators use native mail and accepted collaborators keep access notification" do
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@inviter)
    with_workos do
      with_http([], invitation) do
        stub_method(Resend::Emails, :send, ->(*) { flunk "No duplicate registration email" }) do
          result = collaborator_email(workspace)
          assert result[:sent]
          assert_equal "workos", @invitee.invitation_email_attempts.last.provider
        end
      end
      @invitee.update!(invitation_status: "accepted")
      ENV["RESEND_API_KEY"] = "test"
      ENV["MAILER_FROM_EMAIL"] = "coaching@example.test"
      payloads = []
      stub_method(HTTParty, :get, ->(*_args, **_options) { flunk "Existing account requires no new native admission" }) do
        stub_method(Resend::Emails, :send, ->(payload) { payloads << payload; { "id" => "access_email" } }) do
          result = collaborator_email(workspace)
          assert result[:sent]
          assert_equal "resend", result[:provider]
          assert_includes payloads.first[:text], workspace.name
          assert_includes payloads.first[:text], "https://program.example.test"
          assert_equal "accepted", @invitee.reload.invitation_status
          assert_equal "resend", @invitee.invitation_email_attempts.last.provider
        end
      end
    end
  end

  test "custom delivery is refused before vendor calls unless suppression is explicitly verified" do
    with_workos("WORKOS_INVITATION_EMAIL_DELIVERY" => "custom") do
      stub_method(HTTParty, :get, ->(*_args, **_options) { flunk "Unverified suppression must not mint an emailed invitation" }) do
        result = WorkosInvitationService.send_invite(user: @invitee, invited_by: @inviter) { flunk "No SMTP delivery before suppression" }
        refute result[:sent]
        assert_includes result[:error], "suppression"
      end
    end
  end

  test "custom collaborator configuration failure is visible and recorded without sending" do
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@inviter)
    with_workos("WORKOS_INVITATION_EMAIL_DELIVERY" => "custom", "WORKOS_INVITATION_EMAILS_DISABLED" => "true") do
      stub_method(HTTParty, :get, ->(*_args, **_options) { flunk "No vendor invite before sender configuration" }) do
        result = collaborator_email(workspace)
        refute result[:sent]
        assert_includes result[:error], "not configured"
        assert_equal result[:error], @invitee.invitation_email_attempts.last.error
      end
    end
  end

  test "custom WorkOS configuration failures identify the intended provider without sending" do
    with_workos("WORKOS_INVITATION_EMAIL_DELIVERY" => "custom", "WORKOS_INVITATION_EMAILS_DISABLED" => "true") do
      stub_method(HTTParty, :get, ->(*_args, **_options) { flunk "Configuration failure must precede provider calls" }) do
        result = UserInviteEmailService.send_invite(user: @invitee, invited_by: @inviter)
        refute result[:sent]
        assert_equal "workos", result[:provider]
        assert_nil result[:provider_message_id]
        assert_includes result[:error], "RESEND_API_KEY"
        ENV["RESEND_API_KEY"] = "test"
        result = UserInviteEmailService.send_invite(user: @invitee, invited_by: @inviter)
        assert_equal "workos", result[:provider]
        assert_includes result[:error], "MAILER_FROM_EMAIL"
        ENV["MAILER_FROM_EMAIL"] = "sender@example.test"
        ENV["FRONTEND_URL"] = "https://username:credential@program.example.test"
        result = UserInviteEmailService.send_invite(user: @invitee, invited_by: @inviter)
        assert_equal "workos", result[:provider]
        refute_includes result[:error], "credential"
      end
    end
  end

  test "verified custom delivery preserves branded program link and sends only one SMTP email" do
    previous_frontend_url = ENV["FRONTEND_URL"]
    with_workos("WORKOS_INVITATION_EMAIL_DELIVERY" => "custom", "WORKOS_INVITATION_EMAILS_DISABLED" => "true") do
      ENV["RESEND_API_KEY"] = "test"
      ENV["MAILER_FROM_EMAIL"] = "coaching@example.test"
      ENV["FRONTEND_URL"] = "https://program.example.test"
      payloads = []
      token = "opaque+/?&value=credential"
      with_http([], invitation.merge("token" => token)) do
        stub_method(Resend::Emails, :send, ->(payload) { payloads << payload; { "id" => "custom_email" } }) do
          result = UserInviteEmailService.send_invite(user: @invitee, invited_by: @inviter)
          assert result[:sent]
          assert_equal "resend", result[:provider]
          assert_equal "custom_email", result[:provider_message_id]
          assert_equal "invitation_native", result[:native_invitation_id]
          refute_includes result.values, token
        end
      end
      assert_equal 1, payloads.length
      assert_equal @invitee.email, payloads.first[:to]
      assert_includes payloads.first[:html], "WorkOS"
      refute_includes payloads.first[:html], "Clerk"
      url = URI(payloads.first[:text][/https:\/\/[^ ]+/])
      assert_equal "program.example.test", url.host
      assert_equal "/login", url.path
      query = URI.decode_www_form(url.query).to_h
      assert_equal token, query.fetch("invitation_token")
      assert_equal "https://program.example.test", query.fetch("returnTo")
      assert_equal 1, @requests.count { |method, _url, _options| method == :post }
    end
  ensure
    ENV["FRONTEND_URL"] = previous_frontend_url
  end

  test "custom collaborator invitation preserves its program origin and failed SMTP retains native retry ID" do
    workspace = CoachWorkspaces::Provisioner.ensure_for!(@inviter)
    with_workos("WORKOS_INVITATION_EMAIL_DELIVERY" => "custom", "WORKOS_INVITATION_EMAILS_DISABLED" => "true") do
      ENV["RESEND_API_KEY"] = "test"
      ENV["MAILER_FROM_EMAIL"] = "coaching@example.test"
      payloads = []
      with_http([], invitation) do
        stub_method(Resend::Emails, :send, ->(payload) { payloads << payload; { "id" => "custom_access" } }) do
          result = collaborator_email(workspace)
          assert result[:sent]
          assert_equal "resend", @invitee.invitation_email_attempts.last.provider
          assert_includes payloads.first[:text], workspace.name
          assert_includes payloads.first[:text], "https://program.example.test/login?invitation_token="
        end
      end
      with_http([ invitation ], invitation) do
        stub_method(Resend::Emails, :send, ->(_payload) { raise "secret opaque-invitation-token must not escape" }) do
          result = collaborator_email(workspace)
          refute result[:sent]
          assert_equal "invitation_native", result[:provider_message_id]
          assert_equal "workos", @invitee.invitation_email_attempts.last.provider
          refute_includes result[:error], "opaque-invitation-token"
        end
      end
    end
  end

  private

  def invitation
    { "id" => "invitation_native", "email" => @invitee.email, "organization_id" => nil, "state" => "pending",
      "expires_at" => 7.days.from_now.iso8601, "token" => "opaque-invitation-token",
      "accept_invitation_url" => "https://frontend.example.test/login?invitation_token=opaque-invitation-token" }
  end

  def with_http(rows, response, code: 200, &block)
    stub_method(HTTParty, :get, lambda { |url, **options|
      @requests << [ :get, url, options ]
      WorkosResponse.new(200, url.end_with?("/invitation_native") ? invitation : { "data" => rows, "list_metadata" => {} })
    }) do
      stub_method(HTTParty, :post, lambda { |url, **options|
        @requests << [ :post, url, options ]
        WorkosResponse.new(code, response)
      }, &block)
    end
  end

  def collaborator_email(workspace)
    CoachWorkspaces::CollaboratorInviteEmail.send_invite(user: @invitee, workspace: workspace, role: "reviewer",
      invited_by: @inviter, sign_in_url: "https://program.example.test", requested: true)
  end
end

class WorkosInvitationControllerTest < ActionDispatch::IntegrationTest
  include WorkosAuthTestSupport

  test "authorized native resend preserves local invitation and records WorkOS provider without exposing token" do
    actor = User.create!(clerk_id: "clerk_actor", email: "actor@example.test", role: "admin")
    target = User.create!(clerk_id: "pending_target", email: "target@example.test", invitation_status: "pending")
    with_workos do
      actor.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
      cohort = Cohort.create!(name: "Invited program", created_by_user: actor)
      target.cohort_memberships.create!(cohort: cohort, role: "participant")
      gets = lambda do |url, **_options|
        data = if url.include?("/sso/jwks/")
          { "keys" => [ @signing_jwk.export.deep_stringify_keys ] }
        else
          { "data" => [], "list_metadata" => {} }
        end
        WorkosResponse.new(200, data)
      end
      native = { "id" => "invitation_controller", "email" => target.email, "state" => "pending", "organization_id" => nil,
        "token" => "controller-token", "expires_at" => 7.days.from_now.iso8601 }
      stub_method(HTTParty, :get, gets) do
        stub_method(HTTParty, :post, WorkosResponse.new(200, native)) do
          stub_method(Resend::Emails, :send, ->(*) { flunk "Native provider sends only one invitation email" }) do
            post "/api/v1/admin/users/#{target.id}/resend_invitation", headers: { "Authorization" => "Bearer #{workos_token}" }
            assert_response :success
            assert response.parsed_body.fetch("invitation_sent")
            assert_equal "workos", target.invitation_email_attempts.last.provider
            assert_equal "invitation_controller", target.reload.invitation_email_provider_id
            assert_equal "pending", target.invitation_status
            assert_equal [ cohort.id ], target.cohort_ids
            refute_includes response.body, "controller-token"
          end
        end
      end
    end
  end
end
