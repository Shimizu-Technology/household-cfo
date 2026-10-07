require "test_helper"
require_relative "../support/workos_auth_test_support"
require_relative "../support/workos_browser_auth_test_support"

class ApiAuthBrowserSessionsControllerTest < ActionDispatch::IntegrationTest
  include WorkosAuthTestSupport
  include WorkosBrowserAuthTestSupport

  ORIGIN = "https://householdcfomethod.com"
  HEADERS = { "X-Frontend-Origin" => ORIGIN, "Origin" => ORIGIN, "Sec-Fetch-Site" => "same-origin" }.freeze
  def with_browser_auth
    with_workos do
      @provider = FakeProvider.new(provider_response)
      stub_method(WorkosBrowserAuth::Provider, :new, @provider) do
        with_workos_http { yield }
      end
    end
  end

  def provider_response(claims = {})
    Response.new(user: Profile.new(id: "user_test", email: "workos@example.com", email_verified: true, first_name: "WorkOS", last_name: "User"),
      access_token: workos_token(claims), refresh_token: "private-refresh-v1", authentication_method: "magic_auth")
  end

  def login(return_to: "/organization-access", **options)
    post "/api/auth/login", params: { screen_hint: "sign-in", return_to: return_to }.merge(options), headers: HEADERS, as: :json
    assert_response :success
    JSON.parse(response.body).fetch("authorization_url")
  end

  def callback
    get "/api/auth/callback", params: { state: @provider.options.fetch(:state), code: "opaque-code" }
  end

  def authenticate
    login
    callback
    assert_response :redirect
  end

  test "anonymous session is private and client bound" do
    with_browser_auth do
      get "/api/auth/session", headers: HEADERS
      assert_response :success
      assert_equal({ "client_id" => "client_cfo", "user" => nil }, JSON.parse(response.body))
      assert_equal %w[no-store private], response.headers["Cache-Control"].split(", ").sort
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
    end
  end

  test "disabled provider and missing configuration fail closed" do
    get "/api/auth/session", headers: HEADERS
    assert_response :service_unavailable
    with_workos("WORKOS_API_KEY" => nil) do
      post "/api/auth/login", params: { screen_hint: "sign-in" }, headers: HEADERS, as: :json
      assert_response :service_unavailable
    end
  end

  test "origin custom header content type and fetch metadata prevent csrf" do
    with_browser_auth do
      [ {}, HEADERS.except("X-Frontend-Origin"), HEADERS.except("Origin"), HEADERS.merge("Origin" => "https://evil.example"),
        HEADERS.merge("X-Frontend-Origin" => "https://evil.example", "Origin" => "https://evil.example"), HEADERS.merge("Sec-Fetch-Site" => "cross-site") ].each do |headers|
        post "/api/auth/login", params: { screen_hint: "sign-in" }, headers: headers, as: :json
        assert_response :unauthorized
      end
      post "/api/auth/login", params: { screen_hint: "sign-in" }, headers: HEADERS
      assert_response :unauthorized
      assert_equal 0, WorkosBrowserLoginAttempt.count
    end
  end

  test "get session accepts absent origin but requires custom header and rejects mismatched origin" do
    with_browser_auth do
      get "/api/auth/session", headers: HEADERS.except("Origin")
      assert_response :success
      get "/api/auth/session", headers: HEADERS.merge("Origin" => "https://evil.example")
      assert_response :unauthorized
      get "/api/auth/session"
      assert_response :unauthorized
    end
  end

  test "login uses sdk pkce opaque nonce encrypted verifier and host only cookie" do
    with_browser_auth do
      url = login(invitation_token: "invite.opaque-token", organization_id: "org_test")
      options = @provider.options
      assert_match WorkosBrowserAuth::Sessions::OPAQUE, options[:state]
      assert_equal "#{ORIGIN}/api/auth/callback", options[:redirect_uri]
      assert_equal "S256", options[:code_challenge_method]
      assert_equal "org_test", options[:organization_id]
      assert_equal "invite.opaque-token", options[:invitation_token]
      attempt = WorkosBrowserLoginAttempt.last
      verifier = WorkosBrowserAuth::Encryption.decrypt(attempt.encrypted_verifier, purpose: WorkosBrowserAuth::Encryption::PKCE_PURPOSE)
      assert_equal WorkOS::PKCE.generate_code_challenge(verifier), options[:code_challenge]
      refute_includes attempt.encrypted_verifier, verifier
      refute_includes url, verifier
      assert_cookie_security("cfo_workos_login")
      refute_includes response.body, "refresh_token"
      assert_equal 0, User.where(clerk_id: "workos_user_test").count
    end
  end

  test "return destinations reject external protocol relative encoded slash backslash credentials and auth paths" do
    with_browser_auth do
      [ "https://evil.example/path", "//evil.example", "/%2f/evil.example", "/\\evil.example", "/api/auth/session", "/foo/../api/auth/session", "/auth/callback", "/login", "/?code=private", "/?invitation_token=private", "https://user@householdcfomethod.com/", "/%0aHeader" ].each do |destination|
        post "/api/auth/login", params: { screen_hint: "sign-in", return_to: destination }, headers: HEADERS, as: :json
        assert_response :unauthorized
      end
      assert_equal 0, WorkosBrowserLoginAttempt.count
      login(return_to: "#{ORIGIN}/?participant_program=123#budget")
      assert_equal "#{ORIGIN}/?participant_program=123#budget", WorkosBrowserLoginAttempt.last.return_to
    end
  end

  test "invalid option types do not persist auth attempts" do
    with_browser_auth do
      [ { screen_hint: "invalid" }, { organization_id: "../unsafe" }, { invitation_token: [ "unsafe" ] } ].each do |options|
        post "/api/auth/login", params: { screen_hint: "sign-in" }.merge(options), headers: HEADERS, as: :json
        assert_response :unauthorized
      end
      assert_equal 0, WorkosBrowserLoginAttempt.count
    end
  end

  test "successful callback rotates opaque session and returns only access token in session json" do
    with_browser_auth do
      authenticate
      assert_equal "#{ORIGIN}/organization-access", response.location
      assert_equal 0, WorkosBrowserLoginAttempt.count
      assert_cookie_security("cfo_workos_session")
      record = WorkosBrowserSession.last
      refute_includes record.encrypted_credentials, "private-refresh-v1"
      assert_match(/\A[0-9a-f]{64}\z/, record.cookie_digest)
      get "/api/auth/session", headers: HEADERS
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "user_test", body.fetch("user").fetch("id")
      assert_equal "client_cfo", body.fetch("client_id")
      assert_equal @provider.response.access_token, body.fetch("access_token")
      refute_includes response.body, "private-refresh"
      refute_includes response.body, "refresh_token"
    end
  end

  test "callback replay cannot exchange code twice" do
    with_browser_auth do
      authenticate
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      assert_equal 1, @provider.exchanges.length
      assert_equal 1, WorkosBrowserSession.count
    end
  end

  test "wrong browser expired state changed client and disabled origin cannot consume login" do
    with_browser_auth do
      login
      attempt = WorkosBrowserLoginAttempt.last
      original = cookies["cfo_workos_login"]
      cookies["cfo_workos_login"] = SecureRandom.urlsafe_base64(32)
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      cookies["cfo_workos_login"] = original
      attempt.update!(expires_at: 1.second.ago)
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      attempt.update!(expires_at: 1.minute.from_now, client_id: "client_other")
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      attempt.update!(client_id: "client_cfo", frontend_origin: "https://evil.example")
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      assert_empty @provider.exchanges
    end
  end

  test "callback rechecks saved return destination before exchanging a credential" do
    with_browser_auth do
      login
      WorkosBrowserLoginAttempt.last.update!(return_to: "https://evil.example")
      callback
      assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      assert_empty @provider.exchanges
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "cancelled callback consumes nonce and cleanly returns to sign in" do
    with_browser_auth do
      login
      get "/api/auth/callback", params: { state: @provider.options[:state], error: "access_denied", error_description: "private-detail" }
      assert_equal "#{ORIGIN}/login?auth_error=cancelled", response.location
      assert_equal 0, WorkosBrowserLoginAttempt.count
      refute_includes response.location, "private-detail"
      assert_empty @provider.exchanges
      post "/api/auth/login/status", params: { state: @provider.options[:state] }, headers: HEADERS, as: :json
      assert_equal({ "status" => "cancelled" }, response.parsed_body)
    end
  end

  test "missing callback state recovers at an approved configured app without echoing input" do
    with_browser_auth do
      previous = ENV["FRONTEND_URL"]
      ENV["FRONTEND_URL"] = "https://www.householdcfomethod.com"
      get "/api/auth/callback", params: { code: "private-code", return_to: "https://evil.example" }
      assert_equal "https://www.householdcfomethod.com/login?auth_error=invalid", response.location
      ENV["FRONTEND_URL"] = "https://evil.example/path"
      get "/api/auth/callback", params: { state: "private-unsafe", code: "private-code" }
      assert_response :service_unavailable
      assert_nil response.location
      refute_includes response.body, "private-code"
    ensure
      previous.nil? ? ENV.delete("FRONTEND_URL") : ENV["FRONTEND_URL"] = previous
    end
  end

  test "callback dependency failure strips code state and does not create session" do
    with_browser_auth do
      login
      @provider.failure = WorkosAuth::Unavailable.new("sanitized")
      callback
      assert_equal "#{ORIGIN}/login?auth_error=retry", response.location
      assert_equal 0, WorkosBrowserLoginAttempt.count
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "Google policy continues in hosted AuthKit with fresh nonce and original popup invitation and destination" do
    with_browser_auth do
      previous = ENV["WORKOS_GOOGLE_ENABLED"]
      ENV["WORKOS_GOOGLE_ENABLED"] = "true"
      login(return_to: "/#Review", invitation_token: "private-invitation", authentication_method: "google", popup: true)
      original = @provider.options.dup
      attempt = WorkosBrowserLoginAttempt.last
      refute_includes attempt.encrypted_login_context, "private-invitation"
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Private provider challenge")
      callback
      assert_response :see_other
      assert_equal "authkit", @provider.options.fetch(:provider)
      assert_nil original.fetch(:screen_hint)
      assert_equal "sign-in", @provider.options.fetch(:screen_hint)
      refute_equal original.fetch(:state), @provider.options.fetch(:state)
      refute_equal original.fetch(:code_challenge), @provider.options.fetch(:code_challenge)
      assert_equal "private-invitation", @provider.options.fetch(:invitation_token)
      assert_equal @provider.authorization_url(**@provider.options), response.location
      assert_equal [ "opaque-code" ], @provider.exchanges.map(&:first)
      assert_equal 0, WorkosBrowserSession.count
      assert_equal 1, WorkosBrowserLoginAttempt.count
      fresh = WorkosBrowserLoginAttempt.last
      assert fresh.popup
      assert_equal "#{ORIGIN}/#Review", fresh.return_to
      assert_equal attempt.browser_digest, fresh.browser_digest
      refute_includes response.location, "Private provider challenge"
      @provider.failure = nil
      get "/api/auth/callback", params: { state: original.fetch(:state), code: "do-not-exchange" }
      assert_redirected_to "#{ORIGIN}/login?auth_error=invalid"
      assert_equal [ "opaque-code" ], @provider.exchanges.map(&:first)
      get "/api/auth/callback", params: { state: @provider.options.fetch(:state), code: "hosted-code" }
      assert_redirected_to "#{ORIGIN}/login/complete"
      assert_equal [ "opaque-code", "hosted-code" ], @provider.exchanges.map(&:first)
    ensure
      previous.nil? ? ENV.delete("WORKOS_GOOGLE_ENABLED") : ENV["WORKOS_GOOGLE_ENABLED"] = previous
    end
  end

  test "policy continuation retains organization and handles pre-migration attempts safely" do
    with_browser_auth do
      login(return_to: "/organization-access", organization_id: "org_test", invitation_token: "private-invitation")
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Continue securely")
      callback
      assert_response :see_other
      assert_equal "org_test", @provider.options.fetch(:organization_id)
      assert_equal "private-invitation", @provider.options.fetch(:invitation_token)
      @provider.failure = nil
      login(return_to: "/#Review")
      WorkosBrowserLoginAttempt.last.update!(encrypted_login_context: nil, workos_browser_login_operation_id: nil)
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Continue securely")
      callback
      assert_response :see_other
      assert_equal "authkit", @provider.options.fetch(:provider)
      assert_nil @provider.options[:organization_id]
      assert_nil @provider.options[:invitation_token]
      assert_equal "#{ORIGIN}/#Review", WorkosBrowserLoginAttempt.last.return_to
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "login cancellation and status are browser bound idempotent and consume no credentials" do
    with_browser_auth do
      login(popup: true)
      state = @provider.options.fetch(:state)
      browser = cookies["cfo_workos_login"]
      post "/api/auth/login/status", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "pending" }, response.parsed_body)
      post "/api/auth/login/cancel", params: { state: state }, headers: HEADERS.merge("Origin" => "https://evil.example"), as: :json
      assert_response :unauthorized
      cookies["cfo_workos_login"] = SecureRandom.urlsafe_base64(32)
      post "/api/auth/login/cancel", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "cancelled" }, response.parsed_body)
      assert_nil WorkosBrowserLoginOperation.last.cancelled_at
      assert_equal 1, WorkosBrowserLoginAttempt.count
      post "/api/auth/login/status", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "cancelled" }, response.parsed_body)
      cookies["cfo_workos_login"] = browser
      2.times do
        post "/api/auth/login/cancel", params: { state: state }, headers: HEADERS, as: :json
        assert_response :success
        assert_equal({ "status" => "cancelled" }, response.parsed_body)
      end
      assert WorkosBrowserLoginOperation.last.cancelled_at
      assert_equal 0, WorkosBrowserLoginAttempt.count
      callback
      assert_redirected_to "#{ORIGIN}/login?auth_error=invalid"
      assert_empty @provider.exchanges
      assert_empty @provider.revocations
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "original operation cancels its hosted policy child" do
    with_browser_auth do
      login(popup: true, invitation_token: "private-invitation")
      operation_count = WorkosBrowserLoginOperation.count
      state = @provider.options.fetch(:state)
      operation = WorkosBrowserLoginOperation.last
      @provider.failure = WorkosBrowserAuth::Provider::PolicyRequired.new("Continue securely")
      callback
      assert_response :see_other
      assert_equal operation.id, WorkosBrowserLoginAttempt.last.workos_browser_login_operation_id
      assert_equal operation_count, WorkosBrowserLoginOperation.count
      @provider.failure = nil
      post "/api/auth/login/status", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "pending" }, response.parsed_body)
      post "/api/auth/login/cancel", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "cancelled" }, response.parsed_body)
      callback
      assert_redirected_to "#{ORIGIN}/login?auth_error=invalid"
      assert_equal [ "opaque-code" ], @provider.exchanges.map(&:first)
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "completed operation status matches only its cookie and cancellation never revokes another account" do
    with_browser_auth do
      login(popup: true)
      state = @provider.options.fetch(:state)
      callback
      assert_redirected_to "#{ORIGIN}/login/complete"
      own_cookie = cookies["cfo_workos_session"]
      2.times do
        post "/api/auth/login/cancel", params: { state: state }, headers: HEADERS, as: :json
        assert_equal({ "status" => "complete" }, response.parsed_body)
      end
      post "/api/auth/login/status", params: { state: state }, headers: HEADERS, as: :json
      assert_equal({ "status" => "complete" }, response.parsed_body)
      cookies["cfo_workos_session"] = SecureRandom.urlsafe_base64(32)
      %w[status cancel].each do |action|
        post "/api/auth/login/#{action}", params: { state: state }, headers: HEADERS, as: :json
        assert_equal({ "status" => "account_changed" }, response.parsed_body)
      end
      assert_empty @provider.revocations
      assert_equal 1, WorkosBrowserSession.count
      cookies["cfo_workos_session"] = own_cookie
      travel 11.minutes do
        post "/api/auth/login/status", params: { state: state }, headers: HEADERS, as: :json
        assert_equal({ "status" => "cancelled" }, response.parsed_body)
      end
    end
  end

  test "callback rejects inconsistent subject client issuer organization impersonation and unverified email" do
    with_browser_auth do
      responses = [ provider_response("sub" => "user_other"), provider_response("client_id" => "client_other"),
        provider_response("iss" => "https://evil.example"), provider_response("org_id" => "org_other"),
        provider_response("act" => { "sub" => "operator" }) ]
      unverified = provider_response
      unverified.user.email_verified = false
      responses << unverified
      responses.each do |item|
        @provider.response = item
        login
        callback
        assert_equal "#{ORIGIN}/login?auth_error=invalid", response.location
      end
      assert_equal 0, WorkosBrowserSession.count
    end
  end

  test "expired access token refresh rotates server credentials once and repeats use new access token" do
    with_browser_auth do
      authenticate
      record = WorkosBrowserSession.last
      data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials)
      data["expires_at"] = 1.second.ago.iso8601
      record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
      @provider.response = provider_response
      @provider.response.refresh_token = "private-refresh-v2"
      2.times { get "/api/auth/session", headers: HEADERS; assert_response :success }
      assert_equal [ "private-refresh-v1" ], @provider.refreshes
      assert_equal "private-refresh-v2", WorkosBrowserAuth::Encryption.decrypt(record.reload.encrypted_credentials)["refresh_token"]
    end
  end

  test "refresh outage leaves own session recoverable without clearing cookie" do
    with_browser_auth do
      authenticate
      record = WorkosBrowserSession.last
      data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials).merge("expires_at" => 1.second.ago.iso8601)
      record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
      @provider.failure = WorkosAuth::Unavailable.new("sanitized")
      get "/api/auth/session", headers: HEADERS
      assert_response :service_unavailable
      assert_equal "3", response.headers["Retry-After"]
      assert WorkosBrowserSession.exists?(record.id)
      refute response.headers["Set-Cookie"].to_s.include?("cfo_workos_session")
      @provider.failure = nil
      get "/api/auth/session", headers: HEADERS
      assert_response :success
    end
  end

  test "revoked provider session invalidates only own cookie" do
    with_browser_auth do
      authenticate
      @provider.active_failure = WorkosAuth::InvalidToken.new("sanitized")
      get "/api/auth/session", headers: HEADERS
      assert_response :unauthorized
      assert_equal 0, WorkosBrowserSession.count
      assert response.headers["Set-Cookie"].to_s.include?("cfo_workos_session=")
    end
  end

  test "invalid encrypted credential expired session wrong origin and malformed cookie fail closed" do
    with_browser_auth do
      authenticate
      get "/api/auth/session", headers: HEADERS.merge("X-Frontend-Origin" => "https://www.householdcfomethod.com", "Origin" => "https://www.householdcfomethod.com")
      assert_response :unauthorized
      assert_equal 1, WorkosBrowserSession.count
      authenticate
      WorkosBrowserSession.last.update!(encrypted_credentials: "tampered")
      get "/api/auth/session", headers: HEADERS
      assert_response :unauthorized
      authenticate
      WorkosBrowserSession.last.update!(expires_at: 1.second.ago)
      get "/api/auth/session", headers: HEADERS
      assert_response :unauthorized
      cookies["cfo_workos_session"] = "malformed"
      get "/api/auth/session", headers: HEADERS
      assert_response :unauthorized
    end
  end

  test "logout revokes only current provider session and preserves others" do
    with_browser_auth do
      authenticate
      other = WorkosBrowserSession.last.dup
      other.cookie_digest = WorkosBrowserAuth::Sessions.digest(SecureRandom.urlsafe_base64(32))
      other.provider_session_id = "session_other"
      other.save!
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_response :success
      assert_equal [ "session_test" ], @provider.revocations
      assert WorkosBrowserSession.exists?(other.id)
      assert_equal 1, WorkosBrowserSession.count
      url = JSON.parse(response.body).fetch("redirect_url")
      assert_equal "https://api.workos.com/user_management/sessions/logout", url.split("?").first
      assert_equal ORIGIN, URI.decode_www_form(URI(url).query).to_h["return_to"]
    end
  end

  test "logout outage preserves cookie and local session for retry" do
    with_browser_auth do
      authenticate
      @provider.failure = WorkosAuth::Unavailable.new("sanitized")
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_response :service_unavailable
      assert_equal 1, WorkosBrowserSession.count
      refute response.headers["Set-Cookie"].to_s.include?("cfo_workos_session")
      @provider.failure = nil
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_response :success
    end
  end

  test "anonymous logout is idempotent and cannot be forged from another origin" do
    with_browser_auth do
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS.merge("Origin" => "https://evil.example"), as: :json
      assert_response :unauthorized
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_response :success
      assert_equal ORIGIN, JSON.parse(response.body)["redirect_url"]
      assert_empty @provider.revocations
    end
  end

  test "stale tab logout cannot revoke the new account selected between session read and post" do
    with_browser_auth do
      totals = [ User.count, Household.count, Debt.count, IncomeSource.count ]
      authenticate
      get "/api/auth/session", headers: HEADERS
      assert_response :success
      old_subject = JSON.parse(response.body).fetch("user").fetch("id")
      @provider.response.user.id = "user_second"
      @provider.response.access_token = workos_token({ "sub" => "user_second" })
      authenticate
      fresh = WorkosBrowserSession.last
      cookie = cookies["cfo_workos_session"]
      post "/api/auth/logout", params: { expected_subject: old_subject, expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_account_changed(fresh)
      assert_equal cookie, cookies["cfo_workos_session"]
      assert_equal [ User.count, Household.count, Debt.count, IncomeSource.count ], totals
    end
  end

  test "logout refuses the same user in another organization and accepts matching organization" do
    with_browser_auth do
      @provider.response.organization_id = "org_current"
      @provider.response.access_token = workos_token({ "org_id" => "org_current" })
      authenticate
      fresh = WorkosBrowserSession.last
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: "org_stale" }, headers: HEADERS, as: :json
      assert_account_changed(fresh)
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: "org_current" }, headers: HEADERS, as: :json
      assert_response :success
      assert_equal [ "session_test" ], @provider.revocations
      refute WorkosBrowserSession.exists?(fresh.id)
    end
  end

  test "logout requires explicit expected subject and nullable organization for valid cookie" do
    with_browser_auth do
      authenticate
      fresh = WorkosBrowserSession.last
      [ {}, { expected_subject: "user_test" }, { expected_organization_id: nil },
        { expected_subject: [ "user_test" ], expected_organization_id: nil },
        { expected_subject: "user_test", expected_organization_id: [ "org_current" ] } ].each do |body|
        post "/api/auth/logout", params: body, headers: HEADERS, as: :json
        assert_account_changed(fresh)
      end
    end
  end

  test "already logged out accepts empty body without changing financial records" do
    with_browser_auth do
      totals = [ User.count, Household.count, Debt.count, IncomeSource.count ]
      post "/api/auth/logout", params: {}, headers: HEADERS, as: :json
      assert_response :success
      assert_equal ORIGIN, JSON.parse(response.body).fetch("redirect_url")
      assert_empty @provider.revocations
      assert_equal [ User.count, Household.count, Debt.count, IncomeSource.count ], totals
    end
  end

  test "logout fence reads pending refresh organization and allows expired own access token" do
    with_browser_auth do
      authenticate
      fresh = WorkosBrowserSession.last
      credentials = WorkosBrowserAuth::Encryption.decrypt(fresh.encrypted_credentials)
      credentials["access_token"] = workos_token({ "exp" => 1.minute.ago.to_i })
      credentials["organization_id"] = "org_pending"
      fresh.update!(expires_at: 1.minute.ago, encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt({ "pending_response" => credentials }))
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: nil }, headers: HEADERS, as: :json
      assert_account_changed(fresh)
      post "/api/auth/logout", params: { expected_subject: "user_test", expected_organization_id: "org_pending" }, headers: HEADERS, as: :json
      assert_response :success
      assert_equal [ "session_test" ], @provider.revocations
      refute WorkosBrowserSession.exists?(fresh.id)
    end
  end

  test "logout lock rechecks persisted organization after a stale session object was loaded" do
    with_browser_auth do
      authenticate
      stale = WorkosBrowserSession.last
      persisted = WorkosBrowserSession.find(stale.id)
      credentials = WorkosBrowserAuth::Encryption.decrypt(persisted.encrypted_credentials)
      credentials["organization_id"] = "org_new"
      persisted.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(credentials))
      assert_raises(WorkosBrowserAuth::Sessions::AccountChanged) do
        WorkosBrowserAuth::Sessions.new.logout(stale, origin: ORIGIN, expected_subject: "user_test", expected_organization_id: nil)
      end
      assert WorkosBrowserSession.exists?(stale.id)
      assert_empty @provider.revocations
    end
  end

  test "purpose encryption rejects alternate purpose and parameter filter hides auth secrets" do
    with_browser_auth do
      encrypted = WorkosBrowserAuth::Encryption.encrypt("private-value")
      assert_equal "private-value", WorkosBrowserAuth::Encryption.decrypt(encrypted)
      assert_raises(WorkosAuth::InvalidToken) do
        WorkosBrowserAuth::Encryption.decrypt(encrypted, purpose: WorkosBrowserAuth::Encryption::PKCE_PURPOSE)
      end
      assert_raises(WorkosAuth::InvalidToken) { WorkosBrowserAuth::Encryption.decrypt(encrypted.reverse) }
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter({ "code" => "private", "state" => "private", "refresh_token" => "private", "authorization_url" => "private", "cookie" => "private" })
      assert filtered.values.all? { |value| value == "[FILTERED]" }
    end
  end

  test "successful refresh survives a transient signing key outage without reusing refresh credential" do
    with_browser_auth do
      authenticate
      record = WorkosBrowserSession.last
      data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials).merge("expires_at" => 1.second.ago.iso8601)
      record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
      @provider.response.refresh_token = "rotated-private-value"
      original = WorkosAuth.method(:verify)
      calls = 0
      stub_method(WorkosAuth, :verify, lambda { |token|
        calls += 1
        raise WorkosAuth::Unavailable, "Signing keys unavailable" if calls == 1
        original.call(token)
      }) do
        get "/api/auth/session", headers: HEADERS
        assert_response :service_unavailable
        pending = WorkosBrowserAuth::Encryption.decrypt(record.reload.encrypted_credentials)
        assert_equal "rotated-private-value", pending.fetch("pending_response").fetch("refresh_token")
        get "/api/auth/session", headers: HEADERS
        assert_response :success
      end
      assert_equal [ "private-refresh-v1" ], @provider.refreshes
      refute_includes response.body, "rotated-private-value"
    end
  end

  test "rotated signing key outage stays retriable and preserves refresh rotation until keys recover" do
    with_browser_auth do
      authenticate
      record = WorkosBrowserSession.last
      data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials).merge("expires_at" => 1.second.ago.iso8601)
      record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
      rotated_key = OpenSSL::PKey::RSA.generate(2048)
      rotated_jwk = JWT::JWK.new(rotated_key, "new-signing-key")
      @provider.response.access_token = workos_token(key: rotated_key, kid: "new-signing-key")
      @provider.response.refresh_token = "private-rotated-once"
      original = HTTParty.method(:get)
      recovered = false
      stub_method(HTTParty, :get, lambda { |url, **options|
        if url.include?("/sso/jwks/")
          raise EOFError unless recovered
          WorkosResponse.new(200, { "keys" => [ rotated_jwk.export.deep_stringify_keys ] })
        else
          original.call(url, **options)
        end
      }) do
        2.times do
          get "/api/auth/session", headers: HEADERS
          assert_response :service_unavailable
          assert WorkosBrowserSession.exists?(record.id)
          refute response.headers["Set-Cookie"].to_s.include?("cfo_workos_session")
        end
        recovered = true
        travel 31.seconds do
          get "/api/auth/session", headers: HEADERS
          assert_response :success
          assert_equal @provider.response.access_token, JSON.parse(response.body).fetch("access_token")
        end
      end
      assert_equal [ "private-refresh-v1" ], @provider.refreshes
      assert_equal "private-rotated-once", WorkosBrowserAuth::Encryption.decrypt(record.reload.encrypted_credentials).fetch("refresh_token")
    end
  end

  test "refresh cannot switch the persisted session subject or provider session" do
    with_browser_auth do
      [ { "sub" => "user_other" }, { "sid" => "session_other" } ].each do |claims|
        @provider.response = provider_response
        authenticate
        record = WorkosBrowserSession.last
        data = WorkosBrowserAuth::Encryption.decrypt(record.encrypted_credentials).merge("expires_at" => 1.second.ago.iso8601)
        record.update!(encrypted_credentials: WorkosBrowserAuth::Encryption.encrypt(data))
        @provider.response = provider_response(claims)
        @provider.response.user.id = claims["sub"] if claims["sub"]
        get "/api/auth/session", headers: HEADERS
        assert_response :unauthorized
        refute WorkosBrowserSession.exists?(record.id)
      end
    end
  end

  test "production cookies are secure host only and localhost is forbidden even when configured" do
    with_browser_auth do
      stub_method(Rails, :env, ActiveSupport::StringInquirer.new("production")) do
        https!
        login
        header = response.headers["Set-Cookie"].to_s.downcase
        assert_includes header, "__host-cfo_workos_login="
        assert_includes header, "secure"
        callback
        assert_cookie_security("__Host-cfo_workos_session")
        assert_includes response.headers["Set-Cookie"].to_s.downcase, "secure"
        previous = ENV["FRONTEND_URL"]
        ENV["FRONTEND_URL"] = "http://localhost:5186"
        assert_raises(WorkosAuth::InvalidToken) { WorkosBrowserAuth::Origins.approved!("http://localhost:5186") }
      ensure
        https!(false)
        previous.nil? ? ENV.delete("FRONTEND_URL") : ENV["FRONTEND_URL"] = previous
      end
    end
  end

  test "multiple tabs can complete independent login nonces without sharing credentials" do
    with_browser_auth do
      login
      first = @provider.options[:state]
      login
      second = @provider.options[:state]
      refute_equal first, second
      get "/api/auth/callback", params: { state: first, code: "first-code" }
      assert_response :redirect
      assert_equal 1, WorkosBrowserLoginAttempt.count
      old_cookie_digest = WorkosBrowserSession.last.cookie_digest
      get "/api/auth/callback", params: { state: second, code: "second-code" }
      assert_response :redirect
      assert_equal 0, WorkosBrowserLoginAttempt.count
      assert_equal 1, WorkosBrowserSession.count
      refute_equal old_cookie_digest, WorkosBrowserSession.last.cookie_digest
      assert_equal [ "first-code", "second-code" ], @provider.exchanges.map(&:first)
    end
  end

  test "login rate limit bounds anonymous session allocation" do
    with_browser_auth do
      store = ActiveSupport::Cache::MemoryStore.new
      # The test environment uses NullStore; exercise the framework limiter with
      # a real cache increment, as production's SolidCache does.
      stub_method(Api::Auth::BrowserSessionsController.cache_store, :increment, ->(*args, **options) { store.increment(*args, **options) }) do
        60.times do
          post "/api/auth/login", params: { screen_hint: "sign-in", return_to: "/" }, headers: HEADERS, as: :json
          assert_response :success
        end
        assert_equal 60, WorkosBrowserLoginAttempt.count
        post "/api/auth/login", params: { screen_hint: "sign-in", return_to: "/" }, headers: HEADERS, as: :json
        assert_response :too_many_requests
        assert_equal "60", response.headers["Retry-After"]
        assert_equal 60, WorkosBrowserLoginAttempt.count
      end
    end
  end

  private

  def assert_account_changed(record)
    assert_response :conflict
    assert_equal "account_changed", JSON.parse(response.body).fetch("code")
    assert WorkosBrowserSession.exists?(record.id)
    assert_empty @provider.revocations
    refute response.headers["Set-Cookie"].to_s.include?("cfo_workos_session")
  end

  def assert_cookie_security(name)
    header = response.headers["Set-Cookie"].to_s
    assert_includes header, "#{name}="
    assert_includes header.downcase, "httponly"
    assert_includes header.downcase, "samesite=lax"
    assert_includes header.downcase, "path=/"
    refute_includes header.downcase, "domain="
  end
  test "denied provider admission clears the attempt and offers invited-account recovery without provider details" do
    with_browser_auth do
      login
      @provider.failure = WorkosIdentityResolver::Forbidden.new("private admission detail")
      callback
      assert_equal "#{ORIGIN}/login?auth_error=denied", response.location
      assert_equal 0, WorkosBrowserLoginAttempt.count
      assert_equal 0, WorkosBrowserSession.count
      refute_includes response.body, "private admission detail"
    end
  end
end
