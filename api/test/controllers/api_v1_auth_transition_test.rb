require "test_helper"
require_relative "../support/authentication_transition_test_support"

class ApiV1AuthTransitionTest < ActionDispatch::IntegrationTest
  include AuthenticationTransitionTestSupport

  test "both signed providers preserve one mapped local identity role and household" do
    with_transition do
      user = mapped_user
      household = Household.create!(name: "Preserved transition household", created_by_user: user)
      membership = HouseholdMembership.create!(household: household, user: user, role: "owner")
      with_transition_http do
        [ [ clerk_signed_token, "clerk", "clerk_preserved" ], [ workos_token, "workos", "user_test" ] ].each do |token, provider, subject|
          get "/api/v1/auth/me", headers: bearer(token)
          assert_response :success
          payload = response.parsed_body.fetch("user")
          assert_equal user.id, payload.fetch("id")
          assert_equal provider, payload.fetch("auth_provider")
          assert_equal subject, payload.fetch("auth_subject")
          assert_equal "coach", payload.fetch("role")
          assert_equal "clerk_preserved", user.reload.clerk_id
          assert_equal user.id, membership.reload.user_id
          assert_equal user.id, household.reload.created_by_user_id
        end
      end
    end
  end

  test "WorkOS outage returns unavailable without affecting ordinary Clerk requests" do
    with_transition do
      mapped_user
      with_transition_http(workos_unavailable: true) do
        get "/api/v1/auth/me", headers: bearer(workos_token)
        assert_response :service_unavailable
        stub_method(WorkosAuth, :verify, ->(*) { flunk "Clerk request reached WorkOS verifier" }) do
          get "/api/v1/auth/me", headers: bearer(clerk_signed_token)
          assert_response :success
          assert_equal "clerk", response.parsed_body.fetch("user").fetch("auth_provider")
        end
      end
    end
  end

  test "invalid WorkOS claims signature and algorithm never invoke Clerk" do
    with_transition do
      mapped_user
      with_transition_http do
        stub_method(ClerkAuth, :verify, ->(*) { flunk "Invalid WorkOS token fell back to Clerk" }) do
          tokens = [ workos_token({ "client_id" => "client_other" }), workos_token({ "exp" => 1.hour.ago.to_i }),
            workos_token({ "sid" => nil }), workos_token({ "sub" => "invalid" }), workos_token({ "act" => { "sub" => "operator" } }),
            workos_token({}, key: OpenSSL::PKey::RSA.generate(2048)), workos_token({}, key: "secret", algorithm: "HS256") ]
          tokens.each do |token|
            get "/api/v1/auth/me", headers: bearer(token)
            assert_response :unauthorized
          end
        end
      end
    end
  end

  test "invalid Clerk signatures expiration and actor never invoke WorkOS" do
    with_transition do
      mapped_user
      with_transition_http do
        stub_method(WorkosAuth, :verify, ->(*) { flunk "Invalid Clerk token fell back to WorkOS" }) do
          [ clerk_signed_token({}, key: OpenSSL::PKey::RSA.generate(2048)), clerk_signed_token({ "exp" => 1.hour.ago.to_i }),
            clerk_signed_token({ "act" => { "sub" => "operator" } }) ].each do |token|
            get "/api/v1/auth/me", headers: bearer(token)
            assert_response :unauthorized
          end
        end
      end
    end
  end

  test "unknown malformed and absent issuers never invoke either verifier" do
    with_transition do
      stub_method(ClerkAuth, :verify, ->(*) { flunk "Unknown issuer reached Clerk" }) do
        stub_method(WorkosAuth, :verify, ->(*) { flunk "Unknown issuer reached WorkOS" }) do
          [ workos_token({ "iss" => "https://unknown.fictional.test" }), workos_token({ "iss" => nil }),
            workos_token({ "iss" => [ CLERK_ISSUER ] }), "malformed", "test_token_1", "x" * 16_385 ].each do |token|
            get "/api/v1/auth/me", headers: bearer(token)
            assert_response :unauthorized
          end
        end
      end
    end
  end

  test "missing invalid or ambiguous transition configuration fails unavailable" do
    [ nil, "", "http://clerk.fictional.test", "https://user@clerk.fictional.test", "https://clerk.fictional.test?hint=1",
      "https://api.workos.com/user_management/client_cfo" ].each do |issuer|
      with_transition("CLERK_ISSUER" => issuer) do
        stub_method(HTTParty, :get, ->(*) { flunk "Invalid configuration made an HTTP request" }) do
          get "/api/v1/auth/me", headers: bearer(workos_token)
          assert_response :service_unavailable
        end
      end
    end
    with_transition("AUTH_PROVIDER" => "unknown") do
      get "/api/v1/auth/me", headers: bearer(workos_token)
      assert_response :service_unavailable
    end
  end

  test "retirement rejects Clerk signed sessions while keeping mapped WorkOS access" do
    with_transition do
      mapped_user
      ENV["AUTH_PROVIDER"] = "workos"
      with_transition_http do
        stub_method(ClerkAuth, :verify, ->(*) { flunk "Retired Clerk verifier invoked" }) do
          get "/api/v1/auth/me", headers: bearer(clerk_signed_token)
          assert_response :unauthorized
          get "/api/v1/auth/me", headers: bearer(workos_token)
          assert_response :success
        end
      end
    end
  end

  test "revocation denies both signed providers and retains identity data" do
    with_transition do
      user = mapped_user
      user.update!(invitation_status: "revoked")
      with_transition_http do
        [ clerk_signed_token, workos_token ].each do |token|
          get "/api/v1/auth/me", headers: bearer(token)
          assert_response :forbidden
        end
      end
      assert_equal 1, user.authentication_identities.count
      assert_equal "revoked", user.reload.invitation_status
    end
  end

  test "accepted email cannot silently acquire an unmapped WorkOS identity" do
    with_transition do
      user = mapped_user
      user.authentication_identities.destroy_all
      with_transition_http do
        get "/api/v1/auth/me", headers: bearer(workos_token({ "email" => user.email, "email_verified" => true }))
        assert_response :forbidden
        assert_empty user.authentication_identities
      end
    end
  end

  test "Clerk transition session cannot bypass enterprise SSO even for platform admins" do
    with_transition do
      user = mapped_user
      user.update!(role: "admin")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(user)
      organization = EnterpriseOrganization.create!(name: "Fictional bank", workos_organization_id: "org_bank", coach_workspace: workspace, require_sso: true)
      organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
      with_transition_http do
        get "/api/v1/auth/me", headers: bearer(clerk_signed_token)
        assert_response :forbidden
        assert_equal "accepted", user.reload.invitation_status
      end
    end
  end

  test "WorkOS transition sessions retain server verified SSO policy for associated admins" do
    with_transition do
      user = mapped_user
      user.update!(role: "admin")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(user)
      organization = EnterpriseOrganization.create!(name: "Fictional bank", workos_organization_id: "org_bank", coach_workspace: workspace, require_sso: true)
      organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
      client = Object.new
      client.define_singleton_method(:memberships) { |**| [ { "user_id" => "user_test", "organization_id" => "org_bank", "status" => "active" } ] }
      client.define_singleton_method(:sessions) { |*| [ { "id" => "session_test", "user_id" => "user_test", "organization_id" => "org_bank", "status" => "active", "auth_method" => "password" } ] }
      with_transition_http do
        stub_method(Enterprise::Client, :new, client) do
          get "/api/v1/auth/me", headers: bearer(workos_token({ "org_id" => "org_bank", "auth_method" => "sso" }))
          assert_response :forbidden
          assert_equal "enterprise_sso_required", response.parsed_body.fetch("code")
          assert_equal "accepted", user.reload.invitation_status
        end
      end
    end
  end

  test "transition demo routes require authentication and preserve distinct errors" do
    with_transition do
      get "/api/demo/profile"
      assert_response :unauthorized
      get "/api/demo/profile", headers: bearer("malformed")
      assert_response :unauthorized
    end
    with_transition("CLERK_ISSUER" => nil) do
      get "/api/demo/profile", headers: bearer(workos_token)
      assert_response :service_unavailable
    end
  end

  test "transition BFF preview is available while public authentication stays Clerk" do
    with_transition do
      get "/api/auth/session", headers: { "X-Frontend-Origin" => "https://householdcfomethod.com", "Sec-Fetch-Site" => "same-origin" }
      assert_response :success
      assert_nil response.parsed_body.fetch("user")
      assert_equal "client_cfo", response.parsed_body.fetch("client_id")
      assert_equal "clerk", AuthenticationProvider.public_provider
    end
    with_transition("CLERK_ISSUER" => nil) do
      get "/api/auth/session", headers: { "X-Frontend-Origin" => "https://householdcfomethod.com" }
      assert_response :service_unavailable
    end
  end

  private

  def mapped_user
    user = User.create!(clerk_id: "clerk_preserved", email: "workos@example.com", role: "coach", invitation_status: "accepted")
    user.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
    user
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
