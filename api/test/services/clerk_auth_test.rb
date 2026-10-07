require "test_helper"
require_relative "../support/workos_auth_test_support"

class ClerkAuthTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport
  test "blank tokens are rejected" do
    assert_nil ClerkAuth.verify(nil)
    assert_nil ClerkAuth.verify("")
  end

  test "test token can resolve an existing local user" do
    user = User.create!(clerk_id: "clerk_test_123", email: "tester@example.com", role: "admin")

    payload = ClerkAuth.verify("test_token_#{user.id}")

    assert_equal "clerk_test_123", payload.fetch("sub")
    assert_equal "tester@example.com", payload.fetch("email")
  end

  test "colon test token builds a Clerk-like payload" do
    payload = ClerkAuth.verify("test_token:clerk_payload_123:payload@example.com:Payload:User")

    assert_equal "clerk_payload_123", payload.fetch("sub")
    assert_equal "payload@example.com", payload.fetch("email")
    assert_equal "Payload", payload.fetch("first_name")
    assert_equal "User", payload.fetch("last_name")
  end

  test "configured is true when a JWKS URL or issuer is present" do
    with_clerk_env("CLERK_JWKS_URL" => "https://clerk.example.test/.well-known/jwks.json") do
      assert ClerkAuth.configured?
    end

    with_clerk_env("CLERK_ISSUER" => "https://clerk.example.test") do
      assert ClerkAuth.configured?
    end
  end

  test "real signed Clerk tokens reject nonempty actor claims while ordinary sessions remain valid" do
    key = OpenSSL::PKey::RSA.generate(2048)
    jwk = JWT::JWK.new(key, "clerk_current")
    claims = { "iss" => "https://clerk.example.test", "sub" => "user_signed_clerk", "exp" => 5.minutes.from_now.to_i }
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    with_clerk_env("CLERK_ISSUER" => "https://clerk.example.test") do
      stub_method(HTTParty, :get, WorkosResponse.new(200, { "keys" => [ jwk.export.deep_stringify_keys ] })) do
        token = ->(actor) { JWT.encode(claims.merge("act" => actor), key, "RS256", { "kid" => "clerk_current" }) }
        assert_equal "user_signed_clerk", ClerkAuth.verify(token.call(nil)).fetch("sub")
        assert_equal "user_signed_clerk", ClerkAuth.verify(token.call({})).fetch("sub")
        [ { "sub" => "operator@fictional.test" }, "operator@fictional.test" ].each do |actor|
          assert_nil ClerkAuth.verify(token.call(actor))
        end
        wrong_key = OpenSSL::PKey::RSA.generate(2048)
        forged = JWT.encode(claims, wrong_key, "RS256", { "kid" => "clerk_current" })
        assert_nil ClerkAuth.verify(forged)
      end
    end
  ensure
    Rails.cache = cache
  end

  private

  def with_clerk_env(values)
    previous = %w[CLERK_JWKS_URL CLERK_ISSUER].to_h { |key| [ key, ENV[key] ] }
    previous.each_key { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
