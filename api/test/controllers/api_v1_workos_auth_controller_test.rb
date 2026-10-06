require "test_helper"
require_relative "../support/workos_auth_test_support"

class ApiV1WorkosAuthControllerTest < ActionDispatch::IntegrationTest
  include WorkosAuthTestSupport

  test "explicit mappings preserve local IDs Clerk identity role and household membership" do
    user = create_user(status: "accepted", role: "coach")
    household = Household.create!(name: "Preserved household", created_by_user: user)
    membership = HouseholdMembership.create!(user: user, household: household, role: "owner")
    with_workos do
      with_workos_http do
        WorkosIdentityMapping.bind!(user_id: user.id, subject: "user_test", expected_clerk_id: user.clerk_id, dry_run: false)
        get "/api/v1/auth/me", headers: workos_headers
        assert_response :success
        payload = response.parsed_body.fetch("user")
        assert_equal user.id, payload.fetch("id")
        assert_equal user.clerk_id, payload.fetch("clerk_id")
        assert_equal "workos", payload.fetch("auth_provider")
        assert_equal "user_test", payload.fetch("auth_subject")
        assert_equal "coach", user.reload.role
        assert_equal user.id, membership.reload.user_id
        assert_equal user.id, household.reload.created_by_user_id
        assert_equal 1, @workos_requests.count { |url, _| url.include?("/users/") }
      end
    end
  end

  test "pending invitations link only via server verified email and retain compatibility Clerk ID" do
    user = create_user(status: "pending")
    with_workos do
      with_workos_http do
        get "/api/v1/auth/me", headers: workos_headers
        assert_response :success
        assert_equal "accepted", user.reload.invitation_status
        assert user.invitation_accepted?
        refute user.invitation_pending?
        assert_equal "pending_workos", user.clerk_id
        assert_equal user.id, AuthenticationIdentity.find_by!(subject: "user_test").user_id
      end
    end
  end

  test "accepted accounts cannot relink by email even with signed email claims and bootstrap flags" do
    user = create_user(status: "accepted")
    with_workos do
      ENV["ALLOW_FIRST_USER_BOOTSTRAP"] = "true"
      ENV["CLERK_BOOTSTRAP_ADMIN_EMAILS"] = user.email
      with_workos_http do
        get "/api/v1/auth/me", headers: workos_headers("email" => user.email, "email_verified" => true)
        assert_response :forbidden
        assert_includes response.parsed_body.fetch("error"), "explicit WorkOS identity mapping"
        assert_equal 0, user.authentication_identities.count
      end
    end
  end

  test "unverified email cannot accept an invitation regardless of signed email claims" do
    user = create_user(status: "pending")
    with_workos do
      with_workos_http(profile: workos_profile.merge("email_verified" => false)) do
        get "/api/v1/auth/me", headers: workos_headers("email" => user.email, "email_verified" => true)
        assert_response :forbidden
        assert_equal "pending", user.reload.invitation_status
        assert_empty user.authentication_identities
      end
    end
  end

  test "uninvited accounts cannot bootstrap a WorkOS admin or create users" do
    with_workos do
      ENV["ALLOW_FIRST_USER_BOOTSTRAP"] = "true"
      ENV["CLERK_BOOTSTRAP_ADMIN_EMAILS"] = "workos@example.com"
      with_workos_http do
        assert_no_difference("User.count") do
          get "/api/v1/auth/me", headers: workos_headers
        end
        assert_response :forbidden
      end
    end
  end

  test "revocation denies an already bound identity without deleting account data" do
    user = create_user(status: "revoked")
    with_workos do
      user.authentication_identities.create!(provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
      with_workos_http do
        get "/api/v1/auth/me", headers: workos_headers
        assert_response :forbidden
        assert_includes response.parsed_body.fetch("error"), "revoked"
        assert user.reload.persisted?
      end
    end
  end

  test "wrong provider tokens are rejected and never downgrade to Clerk" do
    with_workos do
      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token:clerk:workos@example.com" }
      assert_response :unauthorized
    end
  end

  test "invalid and unavailable credentials have different statuses" do
    with_workos do
      with_workos_http do
        get "/api/v1/auth/me", headers: workos_headers("exp" => 1.hour.ago.to_i)
        assert_response :unauthorized
      end
    end
    with_workos do
      stub_method(HTTParty, :get, ->(*_args, **_options) { raise Timeout::Error }) do
        get "/api/v1/auth/me", headers: workos_headers
        assert_response :service_unavailable
      end
    end
  end

  test "WorkOS demo routes fail closed with absent tokens and missing configuration" do
    with_workos("WORKOS_API_KEY" => nil) do
      get "/api/demo/profile"
      assert_response :unauthorized
      get "/api/demo/profile", headers: { "Authorization" => "Bearer any-token" }
      assert_response :service_unavailable
      post "/api/demo/mia/messages", params: { message: "hello" }, as: :json
      assert_response :unauthorized
    end
  end

  test "production demo routes fail closed when Clerk configuration is absent" do
    stub_method(Rails.env, :production?, true) do
      get "/api/demo/profile"
      assert_response :unauthorized
      get "/api/demo/profile", headers: { "Authorization" => "Bearer any-token" }
      assert_response :service_unavailable
    end
  end

  test "unknown providers cannot bypass demo authentication" do
    with_workos("AUTH_PROVIDER" => "unknown") do
      get "/api/demo/profile", headers: { "Authorization" => "Bearer any-token" }
      assert_response :service_unavailable
    end
  end

  private

  def create_user(status:, role: "participant")
    User.create!(clerk_id: status == "pending" ? "pending_workos" : "clerk_preserved",
      email: "workos@example.com", role: role, invitation_status: status)
  end

  def workos_headers(claims = {})
    { "Authorization" => "Bearer #{workos_token(claims)}" }
  end
end
