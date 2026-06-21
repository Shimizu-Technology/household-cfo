require "test_helper"

class ApiV1AuthControllerTest < ActionDispatch::IntegrationTest
  AUTH_ENV_KEYS = %w[
    CLERK_JWKS_URL
    CLERK_ISSUER
    CLERK_AUDIENCE
    CLERK_AUDIENCES
    CLERK_SECRET_KEY
    CLERK_BOOTSTRAP_ADMIN_EMAILS
    ALLOW_FIRST_USER_BOOTSTRAP
  ].freeze

  test "rejects missing bearer token" do
    with_auth_env("CLERK_JWKS_URL" => "https://clerk.example.test/.well-known/jwks.json") do
      get "/api/v1/auth/me"

      assert_response :unauthorized
      assert_equal "Missing bearer token", JSON.parse(response.body).fetch("error")
    end
  end

  test "reports missing Clerk configuration for real tokens" do
    with_auth_env({}) do
      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer real.jwt.token" }

      assert_response :service_unavailable
      assert_equal "Clerk authentication is not configured", JSON.parse(response.body).fetch("error")
    end
  end

  test "links an invited participant by email on first Clerk sign in" do
    invited = User.create!(
      clerk_id: "pending_#{SecureRandom.uuid}",
      email: "participant@example.com",
      role: "participant",
      invitation_status: "pending",
      invited_at: 1.day.ago
    )

    get "/api/v1/auth/me", headers: auth_headers("clerk_participant_123", "participant@example.com", "Ariana", "Demo")

    assert_response :success
    body = JSON.parse(response.body).fetch("user")
    assert_equal "participant@example.com", body.fetch("email")
    assert_equal "participant", body.fetch("role")
    assert_equal "accepted", body.fetch("invitation_status")
    assert_equal "clerk_participant_123", invited.reload.clerk_id
    assert invited.accepted_at.present?
    assert invited.last_sign_in_at.present?
  end

  test "rejects uninvited Clerk users without creating a local user" do
    get "/api/v1/auth/me", headers: auth_headers("clerk_uninvited_123", "uninvited@example.com")

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "not been invited"
    assert_nil User.find_by(email: "uninvited@example.com")
  end

  test "bootstrap admin emails can create an initial admin" do
    with_auth_env("CLERK_BOOTSTRAP_ADMIN_EMAILS" => "owner@example.com") do
      get "/api/v1/auth/me", headers: auth_headers("clerk_owner_123", "owner@example.com", "Owner", "Demo")

      assert_response :success
      user = User.find_by!(email: "owner@example.com")
      assert user.admin?
      assert_equal "admin", JSON.parse(response.body).dig("user", "role")
    end
  end

  test "first-user bootstrap only grants the first empty-database sign in" do
    with_auth_env("ALLOW_FIRST_USER_BOOTSTRAP" => "true") do
      get "/api/v1/auth/me", headers: auth_headers("clerk_first_123", "first@example.com", "First", "Admin")
      assert_response :success
      assert_equal "admin", JSON.parse(response.body).dig("user", "role")

      get "/api/v1/auth/me", headers: auth_headers("clerk_second_123", "second@example.com", "Second", "Admin")
      assert_response :forbidden
      assert_includes JSON.parse(response.body).fetch("error"), "not been invited"

      assert_equal 1, User.where(role: "admin").count
      assert_equal "first@example.com", User.find_by!(role: "admin").email
    end
  end

  test "revoked invitations cannot authenticate" do
    User.create!(
      clerk_id: "pending_revoked",
      email: "revoked@example.com",
      role: "participant",
      invitation_status: "revoked"
    )

    get "/api/v1/auth/me", headers: auth_headers("clerk_revoked_123", "revoked@example.com")

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "revoked"
  end

  private

  def auth_headers(clerk_id, email, first_name = "Test", last_name = "User")
    { "Authorization" => "Bearer test_token:#{clerk_id}:#{email}:#{first_name}:#{last_name}" }
  end

  def with_auth_env(values)
    previous = AUTH_ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
    AUTH_ENV_KEYS.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
