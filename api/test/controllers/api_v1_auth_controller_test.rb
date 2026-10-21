require "test_helper"

class ApiV1AuthControllerTest < ActionDispatch::IntegrationTest
  AUTH_ENV_KEYS = %w[AUTH_PROVIDER WORKOS_CLIENT_ID WORKOS_API_KEY WORKOS_ISSUER WORKOS_API_HOSTNAME].freeze

  test "rejects missing bearer token" do
    get "/api/v1/auth/me"

    assert_response :unauthorized
    assert_equal "Missing bearer token", JSON.parse(response.body).fetch("error")
  end

  test "reports missing WorkOS configuration for real tokens" do
    with_auth_env({}) do
      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer real.jwt.token" }

      assert_response :service_unavailable
      assert_equal "WorkOS authentication is not configured", JSON.parse(response.body).fetch("error")
    end
  end

  test "a stale removed provider setting fails closed" do
    [ "clerk", "transition" ].each do |provider|
      with_auth_env("AUTH_PROVIDER" => provider) do
        get "/api/v1/auth/me", headers: { "Authorization" => "Bearer real.jwt.token" }

        assert_response :service_unavailable
        assert_equal "Authentication provider is not configured", JSON.parse(response.body).fetch("error")
      end
    end
  end

  test "test identities are refused outside the test environment" do
    user = User.create!(clerk_id: "test_refused_outside_test", email: "refused@example.com", role: "admin", invitation_status: "accepted")

    with_auth_env({}) do
      with_rails_env("development") do
        get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token_#{user.id}" }
      end
    end

    assert_response :service_unavailable
    assert_equal "WorkOS authentication is not configured", JSON.parse(response.body).fetch("error")
    assert_nil user.reload.last_sign_in_at
  end

  test "test identities link an invited participant by email" do
    invited = User.create!(
      clerk_id: "pending_#{SecureRandom.uuid}",
      email: "participant@example.com",
      role: "participant",
      invitation_status: "pending",
      invited_at: 1.day.ago
    )

    get "/api/v1/auth/me", headers: auth_headers("qa_participant_123", "participant@example.com", "Ariana", "Demo")

    assert_response :success
    body = JSON.parse(response.body).fetch("user")
    assert_equal "participant@example.com", body.fetch("email")
    assert_equal "participant", body.fetch("role")
    assert_equal "accepted", body.fetch("invitation_status")
    assert_equal "test", body.fetch("auth_provider")
    assert_equal "qa_participant_123", invited.reload.clerk_id
    assert_equal "Ariana", invited.first_name
    assert invited.accepted_at.present?
    assert invited.last_sign_in_at.present?
  end

  test "test identities do not take over an accepted account by email" do
    User.create!(clerk_id: "qa_original", email: "accepted@example.com", role: "participant", invitation_status: "accepted")

    get "/api/v1/auth/me", headers: auth_headers("qa_other", "accepted@example.com")

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "already linked"
  end

  test "rejects uninvited identities without creating a local user" do
    get "/api/v1/auth/me", headers: auth_headers("qa_uninvited_123", "uninvited@example.com")

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "not been invited"
    assert_nil User.find_by(email: "uninvited@example.com")
  end

  test "unknown test user ids are unauthorized" do
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token_999999999" }

    assert_response :unauthorized
  end

  test "revoked invitations cannot authenticate" do
    User.create!(
      clerk_id: "pending_revoked",
      email: "revoked@example.com",
      role: "participant",
      invitation_status: "revoked"
    )

    get "/api/v1/auth/me", headers: auth_headers("qa_revoked_123", "revoked@example.com")

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "revoked"
  end

  test "platform administrators can deliberately use global mode or select one workspace" do
    admin = User.create!(
      clerk_id: "qa_platform_admin",
      email: "platform-admin@example.com",
      role: "admin",
      invitation_status: "accepted"
    )
    workspace = CoachWorkspaces::Provisioner.ensure_for!(admin)
    headers = auth_headers(admin.clerk_id, admin.email, "Platform", "Admin")

    get "/api/v1/auth/me", headers: headers
    assert_response :success
    assert_nil response.parsed_body.dig("user", "active_coach_workspace")

    get "/api/v1/auth/me", headers: headers.merge("X-Coach-Workspace-Id" => workspace.id.to_s)
    assert_response :success
    assert_equal workspace.id, response.parsed_body.dig("user", "active_coach_workspace", "id")
  end

  test "accepted local test identities do not write sign in activity on read requests" do
    user = User.create!(clerk_id: "quiet-test-reader", email: "quiet-test-reader@example.com", role: "participant", invitation_status: "accepted")
    2.times do
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token_#{user.id}" }
      end
      assert_response :success
      assert_empty statements.grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
    end
    user.update!(invitation_status: "revoked")
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer test_token_#{user.id}" }
    assert_response :forbidden
  end

  private

  def auth_headers(subject, email, first_name = "Test", last_name = "User")
    { "Authorization" => "Bearer test_token:#{subject}:#{email}:#{first_name}:#{last_name}" }
  end

  def with_rails_env(name)
    original = Rails.method(:env)
    Rails.singleton_class.send(:define_method, :env) { ActiveSupport::EnvironmentInquirer.new(name) }
    yield
  ensure
    Rails.singleton_class.send(:remove_method, :env)
    Rails.singleton_class.send(:define_method, :env, original)
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
