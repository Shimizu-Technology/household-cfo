require "test_helper"
require_relative "../support/workos_auth_test_support"

class WorkosBrowserAuthProviderTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  test "official SDK authorization url contains exact host callback and PKCE parameters" do
    with_workos do
      provider = WorkosBrowserAuth::Provider.new
      url = provider.authorization_url(redirect_uri: "https://householdcfomethod.com/api/auth/callback", provider: "authkit", state: "nonce",
        code_challenge: "challenge", code_challenge_method: "S256")
      uri = URI(url)
      assert_equal "https://api.workos.com/user_management/authorize", url.split("?").first
      query = URI.decode_www_form(uri.query).to_h
      assert_equal "client_cfo", query["client_id"]
      assert_equal "code", query["response_type"]
      assert_equal "challenge", query["code_challenge"]
      assert_equal "S256", query["code_challenge_method"]
      refute_includes url, "test-secret"
      google_url = provider.authorization_url(redirect_uri: "https://householdcfomethod.com/api/auth/callback", provider: "GoogleOAuth", screen_hint: nil, state: "nonce",
        code_challenge: "challenge", code_challenge_method: "S256")
      google_query = URI.decode_www_form(URI(google_url).query).to_h
      assert_equal "GoogleOAuth", google_query.fetch("provider")
      assert_equal "challenge", google_query.fetch("code_challenge")
      assert_equal "S256", google_query.fetch("code_challenge_method")
      refute google_query.key?("screen_hint")
      logout = provider.logout_url(session_id: "session_own", origin: "https://householdcfomethod.com")
      assert_equal "https://api.workos.com/user_management/sessions/logout", logout.split("?").first
    end
  end

  test "official client uses server secret namespaced issuer timeout and zero automatic retries" do
    with_workos do
      captured = nil
      original = WorkOS::Client.method(:new)
      stub_method(WorkOS::Client, :new, lambda { |**options| captured = options; original.call(**options) }) do
        WorkosBrowserAuth::Provider.new
      end
      assert_equal "client_cfo", captured[:client_id]
      assert_equal "test-secret", captured[:api_key]
      assert_equal 5, captured[:timeout]
      assert_equal 0, captured[:max_retries]
      assert_equal WorkosAuth.issuer, captured[:jwt_issuer]
      assert_nil captured[:logger]
    end
  end

  test "SDK code exchange and refresh errors are sanitized dependency or invalid session errors" do
    with_workos do
      management = Object.new
      management.define_singleton_method(:authenticate_with_code) { |**| raise WorkOS::APIConnectionError.new(message: "private credentials") }
      management.define_singleton_method(:authenticate_with_refresh_token) { |**| raise WorkOS::InvalidRequestError.new(message: "private refresh", http_status: 400, code: "invalid_grant") }
      client = WorkOS::Client.new(api_key: "test-secret", client_id: "client_cfo")
      stub_method(client, :user_management, management) do
        stub_method(WorkOS::Client, :new, client) do
          provider = WorkosBrowserAuth::Provider.new
          error = assert_raises(WorkosAuth::Unavailable) { provider.exchange(code: "private-code", verifier: "private-verifier") }
          refute_includes error.message, "private"
          error = assert_raises(WorkosAuth::InvalidToken) { provider.refresh(refresh_token: "private-token") }
          refute_includes error.message, "private"
          [ EOFError, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError, Net::HTTPBadResponse ].each do |error_class|
            management.define_singleton_method(:authenticate_with_code) { |**| raise error_class, "private-response" }
            error = assert_raises(WorkosAuth::Unavailable) { provider.exchange(code: "private-code", verifier: "private-verifier") }
            refute_includes error.message, "private"
          end
        end
      end
    end
  end

  test "provider state requires exact subject active session and no impersonator" do
    with_workos do
      client = Enterprise::Client.new
      row = { "id" => "session_test", "user_id" => "user_test", "status" => "active" }
      stub_method(Enterprise::Client, :new, client) do
        stub_method(client, :sessions, [ row ]) do
          provider = WorkosBrowserAuth::Provider.new
          assert_equal row, provider.active_session!(subject: "user_test", session_id: "session_test")
          [ { "status" => "revoked" }, { "user_id" => "user_other" }, { "impersonator" => { "email" => "private@example.test" } } ].each do |change|
            row.merge!(change)
            assert_raises(WorkosAuth::InvalidToken) { provider.active_session!(subject: "user_test", session_id: "session_test") }
          end
        end
        stub_method(client, :sessions, ->(*) { raise Enterprise::Client::Unavailable, "private" }) do
          assert_raises(WorkosAuth::Unavailable) { WorkosBrowserAuth::Provider.new.active_session!(subject: "user_test", session_id: "session_test") }
        end
      end
    end
  end

  test "Magic Auth official credential errors and policy challenges are sanitized" do
    with_workos do
      management = Object.new
      client = WorkOS::Client.new(api_key: "test-secret", client_id: "client_cfo")
      stub_method(client, :user_management, management) do
        stub_method(WorkOS::Client, :new, client) do
          %w[invalid_one_time_code one_time_code_expired].each do |code|
            management.define_singleton_method(:authenticate_with_magic_auth) do |**|
              raise WorkOS::InvalidRequestError.new(message: "private code response", http_status: 400, code: code)
            end
            error = assert_raises(WorkosAuth::InvalidToken) do
              WorkosBrowserAuth::Provider.new.authenticate_magic_auth(email: "private@example.com", code: "123456")
            end
            refute_includes error.message, "private"
          end
          WorkosBrowserAuth::Provider::POLICY_ERRORS.each do |code|
            management.define_singleton_method(:authenticate_with_magic_auth) do |**|
              raise WorkOS::ForbiddenRequestError.new(message: "private pending response", http_status: 403,
                body: { "error" => code, "pending_authentication_token" => "secret-pending" })
            end
            error = assert_raises(WorkosBrowserAuth::Provider::PolicyRequired) do
              WorkosBrowserAuth::Provider.new.authenticate_magic_auth(email: "private@example.com", code: "123456")
            end
            refute_includes error.message, "private"
            refute_includes error.message, "secret-pending"
          end
          management.define_singleton_method(:create_magic_auth) do |**|
            raise WorkOS::RateLimitExceededError.new(message: "private response", http_status: 429)
          end
          assert_raises(WorkosBrowserAuth::Provider::RateLimited) do
            WorkosBrowserAuth::Provider.new.create_magic_auth(email: "private@example.com")
          end
        end
      end
    end
  end

  test "origin policy rejects noncanonical origins and confines development loopback to configured URLs" do
    with_workos do
      previous = ENV["FRONTEND_URL"]
      ENV["FRONTEND_URL"] = "http://127.0.0.1:5186"
      assert_equal "http://127.0.0.1:5186", WorkosBrowserAuth::Origins.approved!("http://127.0.0.1:5186")
      [ "http://127.0.0.1:5187", "https://householdcfomethod.com/", "https://householdcfomethod.com:443", "https://householdcfomethod.com:444", "http://householdcfomethod.com", "https://user@householdcfomethod.com", "https://householdcfomethod.com?query=1", "https://householdcfomethod.com#fragment" ].each do |origin|
        assert_raises(WorkosAuth::InvalidToken) { WorkosBrowserAuth::Origins.approved!(origin) }
      end
    ensure
      previous.nil? ? ENV.delete("FRONTEND_URL") : ENV["FRONTEND_URL"] = previous
    end
  end
  test "uninvited Google signup is admission denial rather than a temporary provider outage" do
    with_workos do
      management = Object.new
      management.define_singleton_method(:authenticate_with_code) do |**|
        raise WorkOS::InvalidRequestError.new(message: "private signup detail", http_status: 400, code: "sign_up_not_allowed")
      end
      client = WorkOS::Client.new(api_key: "test-secret", client_id: "client_cfo")
      stub_method(client, :user_management, management) do
        stub_method(WorkOS::Client, :new, client) do
          error = assert_raises(WorkosIdentityResolver::Forbidden) { WorkosBrowserAuth::Provider.new.exchange(code: "private-code", verifier: "private-verifier") }
          refute_includes error.message, "private"
        end
      end
    end
  end
end
