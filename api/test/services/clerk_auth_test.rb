require "test_helper"

class ClerkAuthTest < ActiveSupport::TestCase
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
