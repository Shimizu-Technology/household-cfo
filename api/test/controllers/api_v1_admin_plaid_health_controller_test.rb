require "test_helper"

class ApiV1AdminPlaidHealthControllerTest < ActionDispatch::IntegrationTest
  test "admin receives metadata-only Plaid connection health" do
    admin = create_user("health-admin@example.com", "admin")
    household = HouseholdFinance::WorkspaceResolver.new(admin).household
    item = household.plaid_items.create!(
      connected_by_user: admin,
      plaid_item_id: "private-plaid-item-id",
      access_token: "private-access-token",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test",
      last_successful_update_at: 2.hours.ago
    )
    item.plaid_accounts.create!(plaid_account_id: "private-account-id", name: "Checking", account_type: "depository")

    get "/api/v1/admin/plaid_health", headers: auth_headers(admin)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal 1, payload.dig("summary", "connected")
    assert_equal "healthy", payload.dig("items", 0, "health", "state")
    assert_equal "Sandbox Bank", payload.dig("items", 0, "institution_name")
    refute_includes response.body, "private-plaid-item-id"
    refute_includes response.body, "private-account-id"
    refute_includes response.body, "private-access-token"
  end

  test "participant cannot inspect connection health across households" do
    participant = create_user("health-participant@example.com", "participant")

    get "/api/v1/admin/plaid_health", headers: auth_headers(participant)

    assert_response :forbidden
  end

  private

  def create_user(email, role)
    User.create!(clerk_id: "health_#{SecureRandom.hex(6)}", email: email, role: role, invitation_status: "accepted")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
