require "test_helper"
require_relative "../support/workos_auth_test_support"
require_relative "../support/workos_browser_auth_test_support"

class ApiAuthEmailChallengesControllerTest < ActionDispatch::IntegrationTest
  include WorkosAuthTestSupport
  include WorkosBrowserAuthTestSupport
  ORIGIN = "https://householdcfomethod.com"
  HEADERS = { "X-Frontend-Origin" => ORIGIN, "Origin" => ORIGIN, "Sec-Fetch-Site" => "same-origin" }.freeze
  Delivery = Struct.new(:email, :expires_at, :user_id, :radar_auth_attempt_id, :code, keyword_init: true)

  def with_auth
    with_workos do
      response = Response.new(user: Profile.new(id: "user_test", email: "workos@example.com", email_verified: true),
        access_token: workos_token, refresh_token: "secret-refresh", authentication_method: "MagicAuth")
      @provider = FakeProvider.new(response)
      @deliveries, @verifications = [], []
      @provider.define_singleton_method(:create_magic_auth) do |**options|
        raise failure if failure
        Delivery.new(email: options.fetch(:email), expires_at: 10.minutes.from_now.iso8601, user_id: "user_test", code: "123456")
      end
      @provider.define_singleton_method(:authenticate_magic_auth) do |**options|
        raise failure if failure
        raise WorkosAuth::InvalidToken, "Private provider error" unless options[:code] == "123456"
        response
      end
      stub_method(WorkosBrowserAuth::Provider, :new, @provider) do
        with_workos_http { yield }
      end
    end
  end

  def start_email(headers: HEADERS, **options)
    post "/api/auth/email/start", params: { email: " WorkOS@example.com ", return_to: "/#AskMia" }.merge(options), headers: headers, as: :json
    assert_response :success
    response.parsed_body
  end

  def verify_email(challenge, code = "123456", headers: HEADERS)
    post "/api/auth/email/verify", params: { challenge_id: challenge.fetch("challenge_id"), code: code }, headers: headers, as: :json
  end

  def mapped_user
    user = User.create!(email: "workos@example.com", clerk_id: "old-clerk", invitation_status: "accepted", role: "participant")
    AuthenticationIdentity.create!(user: user, provider: "workos", issuer: WorkosAuth.issuer, subject: "user_test")
    user
  end

  test "verified email establishes same account session without serializing provider credentials" do
    with_auth do
      user = mapped_user
      household = Household.create!(name: "Existing household", created_by_user: user)
      before = [ User.count, Household.count, Debt.count, IncomeSource.count ]
      challenge = start_email
      assert_equal "workos@example.com", challenge.fetch("email")
      assert_equal "code", challenge.fetch("step")
      assert_equal 60, challenge.fetch("resend_after")
      refute_includes response.body, "123456"
      refute_includes WorkosEmailChallenge.last.encrypted_context, "workos@example.com"
      verify_email(challenge)
      assert_response :success
      assert_equal({ "step" => "complete", "return_to" => "#{ORIGIN}/#AskMia" }, response.parsed_body)
      assert_equal 1, WorkosBrowserSession.count
      assert_equal 0, WorkosEmailChallenge.count
      assert_equal "user_test", WorkosBrowserSession.last.subject
      assert_equal user.id, household.reload.created_by_user_id
      assert_equal before, [ User.count, Household.count, Debt.count, IncomeSource.count ]
      refute_includes response.body, "secret-refresh"
      assert_includes response.headers["Set-Cookie"].to_s.downcase, "httponly"
      verify_email(challenge)
      assert_response :gone
      assert_equal 1, WorkosBrowserSession.count
      post "/api/auth/email/resend", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
      assert_response :gone
    end
  end

  test "invalid code retains attempt counts and cannot erase existing session" do
    with_auth do
      mapped_user
      first = start_email
      verify_email(first)
      old_cookie = cookies["cfo_workos_session"]
      challenge = start_email
      5.times do |index|
        verify_email(challenge, "000000")
        assert_response :unauthorized
        assert_equal "email_code_invalid", response.parsed_body.fetch("code")
        assert_equal index + 1, WorkosEmailChallenge.last.verification_attempts
        assert_equal old_cookie, cookies["cfo_workos_session"]
        refute_includes response.headers["Set-Cookie"].to_s, "cfo_workos_login="
      end
      verify_email(challenge)
      assert_response :gone
      assert_equal 1, WorkosBrowserSession.count
    end
  end

  test "origin browser and expiry bind challenges and cancel is idempotent" do
    with_auth do
      challenge = start_email
      verify_email(challenge, headers: HEADERS.merge("Origin" => "https://evil.example"))
      assert_response :unauthorized
      cookies.delete("cfo_workos_login")
      verify_email(challenge)
      assert_response :gone
      refute WorkosBrowserSession.exists?
      challenge = start_email
      post "/api/auth/email/cancel", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
      assert_response :no_content
      verify_email(challenge)
      assert_response :gone
      post "/api/auth/email/cancel", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
      assert_response :no_content
      challenge = start_email
      travel 11.minutes do
        verify_email(challenge)
        assert_response :gone
      end
    end
  end

  test "resend enforces cooldown and bounds delivery across challenges" do
    with_auth do
      challenge = start_email
      post "/api/auth/email/resend", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
      travel 61.seconds do
        post "/api/auth/email/resend", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
        assert_response :success
        assert_equal challenge.fetch("challenge_id"), response.parsed_body.fetch("challenge_id")
      end
    end
    with_auth do
      WorkosEmailDeliveryLimit.delete_all
      previous_count = WorkosEmailChallenge.count
      3.times { start_email }
      post "/api/auth/email/start", params: { email: "workos@example.com", return_to: "/" }, headers: HEADERS, as: :json
      assert_response :too_many_requests
      assert_equal previous_count + 3, WorkosEmailChallenge.count
    end
  end

  test "pending policy redirects through bound hosted AuthKit without exposing pending tokens" do
    with_auth do
      mapped_user
      challenge = start_email(invitation_token: "private-invitation")
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Continue securely")
      verify_email(challenge)
      assert_response :success
      assert_equal "redirect", response.parsed_body.fetch("step")
      assert_equal "authkit", @provider.options.fetch(:provider)
      assert_equal "workos@example.com", @provider.options.fetch(:login_hint)
      assert_equal "private-invitation", @provider.options.fetch(:invitation_token)
      assert_equal 0, WorkosEmailChallenge.count
      assert_equal 0, WorkosBrowserSession.count
      assert_equal 1, WorkosBrowserLoginAttempt.count
    end
  end

  test "a late email code refreshes the same browser cookie through hosted policy completion" do
    with_auth do
      mapped_user
      challenge = start_email
      browser = cookies["cfo_workos_login"]
      travel 9.minutes
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Continue securely")
      verify_email(challenge)
      assert_response :success
      assert_equal "redirect", response.parsed_body.fetch("step")
      assert_equal browser, cookies["cfo_workos_login"]
      expiry = response.headers["Set-Cookie"].to_s[/expires=([^;]+)/i, 1]
      assert expiry
      assert_in_delta 10.minutes.from_now.to_i, Time.httpdate(expiry).to_i, 1
      travel 2.minutes
      @provider.failure = nil
      @provider.response.access_token = workos_token
      get "/api/auth/callback", params: { state: @provider.options.fetch(:state), code: "hosted-code" }
      assert_redirected_to "#{ORIGIN}/#AskMia"
      assert_equal 1, WorkosBrowserSession.count
    ensure
      travel_back
    end
  end

  test "hourly email and source limits are atomic and allow different participants from one office" do
    with_auth do
      mapped_user
      before_users = User.count
      first = HEADERS.merge("REMOTE_ADDR" => "203.0.113.1")
      second = HEADERS.merge("REMOTE_ADDR" => "203.0.113.2")
      third = HEADERS.merge("REMOTE_ADDR" => "203.0.113.3")
      3.times { start_email(headers: first) }
      travel 61.seconds
      2.times { start_email(headers: first) }
      before = WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
      post "/api/auth/email/start", params: { email: "workos@example.com", return_to: "/" }, headers: first, as: :json
      assert_response :too_many_requests
      assert_operator response.parsed_body.fetch("retry_after_sec"), :>, 3500
      assert_equal response.parsed_body.fetch("retry_after_sec").to_s, response.headers["Retry-After"]
      assert_equal before, WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
      start_email(headers: second)
      travel 61.seconds
      3.times { start_email(headers: second) }
      travel 61.seconds
      start_email(headers: second)
      before = WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
      post "/api/auth/email/start", params: { email: "workos@example.com", return_to: "/" }, headers: third, as: :json
      assert_response :too_many_requests
      assert_equal before, WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
      30.times { |index| start_email(headers: first, email: "office-participant-#{index}@fictional.example") }
      assert_equal before_users, User.count
      travel 1.hour
      3.times { start_email(headers: first) }
      post "/api/auth/email/start", params: { email: "workos@example.com", return_to: "/" }, headers: first, as: :json
      assert_response :too_many_requests
    ensure
      travel_back
    end
  end

  test "missing and invalid source addresses share a bounded unknown-source allowance" do
    with_auth do
      limiter = WorkosBrowserAuth::EmailChallenges.new(provider: @provider)
      3.times { limiter.send(:delivery_limit!, "workos@example.com", ip_address: nil) }
      travel 61.seconds
      2.times { limiter.send(:delivery_limit!, "workos@example.com", ip_address: "invalid-address") }
      before = WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
      assert_raises(WorkosBrowserAuth::EmailChallenges::RateLimited) do
        limiter.send(:delivery_limit!, "workos@example.com", ip_address: nil)
      end
      assert_equal before, WorkosEmailDeliveryLimit.order(:id).pluck(:id, :delivery_count, :window_started_at, :updated_at)
    ensure
      travel_back
    end
  end

  test "an uncertain resend keeps its cooldown and does not erase verification attempts" do
    with_auth do
      mapped_user
      challenge = start_email
      verify_email(challenge, "000000")
      assert_response :unauthorized
      travel 61.seconds do
        @provider.failure = WorkosAuth::Unavailable.new("Private delivery response")
        post "/api/auth/email/resend", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
        assert_response :service_unavailable
        refute_includes response.body, "Private delivery response"
        assert_equal 1, WorkosEmailChallenge.last.verification_attempts
        assert_operator WorkosEmailChallenge.last.resend_at, :>, Time.current
        @provider.failure = nil
        post "/api/auth/email/resend", params: { challenge_id: challenge.fetch("challenge_id") }, headers: HEADERS, as: :json
        assert_response :too_many_requests
        verify_email(challenge)
        assert_response :success
      end
    end
  end

  test "revocation and conflicting accepted identities cannot gain a new session" do
    with_auth do
      user = mapped_user
      challenge = start_email
      user.update!(invitation_status: "revoked")
      verify_email(challenge)
      assert_response :forbidden
      assert_equal "program_access_denied", response.parsed_body.fetch("code")
      refute WorkosBrowserSession.exists?
    end
  end

  test "uninvited email has same public code step without provider account creation" do
    with_auth do
      User.create!(email: "unrelated-admin@fictional.example", clerk_id: "unrelated-admin", role: "admin", invitation_status: "accepted")
      @provider.define_singleton_method(:create_magic_auth) { |**| raise "Must not create an uninvited WorkOS account" }
      assert_no_difference [ "User.count", "AuthenticationIdentity.count", "WorkosBrowserSession.count" ] do
        challenge = start_email(invitation_token: "untrusted-token-is-not-admission")
        assert_equal "code", challenge.fetch("step")
        assert_equal "workos@example.com", challenge.fetch("email")
        verify_email(challenge)
        assert_response :unauthorized
        assert_equal "email_code_invalid", response.parsed_body.fetch("code")
      end
      refute User.where("LOWER(email) = ?", "workos@example.com").exists?
    end
  end

  test "a pending invite uses provider verified identity and preserves the invited role" do
    with_auth do
      user = User.create!(email: "workos@example.com", clerk_id: "pending_email", invitation_status: "pending", role: "coach")
      verify_email(start_email(invitation_token: "invite-proof"))
      assert_response :success
      assert_equal "accepted", user.reload.invitation_status
      assert_equal "coach", user.role
      assert_equal "pending_email", user.clerk_id
      assert_equal "user_test", user.authentication_identities.sole.subject
    end
  end

  test "Magic Auth cannot bypass a required enterprise SSO session" do
    with_auth do
      user = mapped_user
      operator = User.create!(email: "operator@fictional.test", clerk_id: "operator_test", role: "admin")
      workspace = CoachWorkspaces::Provisioner.ensure_for!(operator)
      organization = EnterpriseOrganization.create!(name: "Fictional SSO", coach_workspace: workspace,
        workos_organization_id: "org_ssotest", require_sso: true)
      organization.enterprise_memberships.create!(user: user, workos_user_id: "user_test", status: "active", it_admin: true)
      @provider.response.organization_id = "org_ssotest"
      @provider.response.access_token = workos_token({ "org_id" => "org_ssotest" })
      client = Enterprise::Client.new
      stub_method(client, :memberships, [ { "user_id" => "user_test", "organization_id" => "org_ssotest", "status" => "active" } ]) do
        stub_method(client, :sessions, [ { "id" => "session_test", "user_id" => "user_test", "organization_id" => "org_ssotest", "status" => "active", "auth_method" => "magic_auth" } ]) do
          stub_method(Enterprise::Client, :new, client) do
            verify_email(start_email)
            assert_response :success
            assert_equal "redirect", response.parsed_body.fetch("step")
            assert_equal "authkit", @provider.options.fetch(:provider)
            assert_equal [ "session_test" ], @provider.revocations
            assert_equal 0, WorkosBrowserSession.count
            assert_equal "participant", user.reload.role
          end
        end
      end
    end
  end

  test "popup cancellation never exposes provider details and regular login keeps original destination" do
    with_auth do
      post "/api/auth/login", params: { screen_hint: "sign-in", return_to: "/#Review", popup: true }, headers: HEADERS, as: :json
      get "/api/auth/callback", params: { state: @provider.options.fetch(:state), error: "access_denied", error_description: "private provider message" }
      assert_redirected_to "#{ORIGIN}/login/complete?auth_error=cancelled"
      refute_includes response.body, "private provider"
      assert_equal 0, WorkosBrowserSession.count
      post "/api/auth/login", params: { screen_hint: "sign-in", return_to: "/#Review" }, headers: HEADERS, as: :json
      get "/api/auth/callback", params: { state: @provider.options.fetch(:state), code: "valid-code" }
      assert_redirected_to "#{ORIGIN}/#Review"
    end
  end

  test "Google is explicitly configured and popup callback returns only completion route" do
    with_auth do
      previous = ENV["WORKOS_GOOGLE_ENABLED"]
      ENV.delete("WORKOS_GOOGLE_ENABLED")
      get "/api/auth/options", headers: HEADERS
      assert_equal false, response.parsed_body.fetch("google_enabled")
      post "/api/auth/login", params: { screen_hint: "sign-in", authentication_method: "google", popup: true }, headers: HEADERS, as: :json
      assert_response :unauthorized
      ENV["WORKOS_GOOGLE_ENABLED"] = "true"
      get "/api/auth/options", headers: HEADERS
      assert_equal true, response.parsed_body.fetch("google_enabled")
      post "/api/auth/login", params: { screen_hint: "sign-in", return_to: "/#Review", authentication_method: "google", popup: true }, headers: HEADERS, as: :json
      assert_response :success
      assert_equal "GoogleOAuth", @provider.options.fetch(:provider)
      assert WorkosBrowserLoginAttempt.last.popup
      get "/api/auth/callback", params: { state: @provider.options.fetch(:state), code: "code" }
      assert_redirected_to "#{ORIGIN}/login/complete"
      post "/api/auth/login", params: { screen_hint: "sign-in", popup: "true" }, headers: HEADERS, as: :json
      assert_response :unauthorized
    ensure
      previous.nil? ? ENV.delete("WORKOS_GOOGLE_ENABLED") : ENV["WORKOS_GOOGLE_ENABLED"] = previous
    end
  end
end
