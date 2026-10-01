require "test_helper"

class ApiV1AccountsControllerTest < ActionDispatch::IntegrationTest
  test "participant creates updates archives and restores an account without losing unknown state" do
    user = create_user("accounts-crud@example.com")
    household = HouseholdFinance::WorkspaceResolver.new(user).household

    post "/api/v1/accounts", params: { account: { label: "Savings", account_type: "savings", balance: nil } }, headers: headers(user, "create"), as: :json
    assert_response :created
    account = household.accounts.find(response.parsed_body.dig("account", "id"))
    assert_not account.balance_known?
    assert_nil response.parsed_body.dig("account", "balance")

    patch "/api/v1/accounts/#{account.id}", params: { account: { balance: 0, balance_as_of_on: "2026-10-01" } }, headers: headers(user, "update"), as: :json
    assert_response :success
    assert account.reload.balance_known?
    assert_equal 0, account.balance_cents
    assert_equal Date.new(2026, 10, 1), account.balance_as_of_on

    delete "/api/v1/accounts/#{account.id}", headers: headers(user, "archive")
    assert_response :success
    assert_not account.reload.active?
    post "/api/v1/accounts/#{account.id}/restore", headers: headers(user, "restore"), as: :json
    assert_response :success
    assert account.reload.active?
  end

  test "participant cannot mutate another household account" do
    owner = create_user("account-owner@example.com")
    intruder = create_user("account-intruder@example.com")
    account = HouseholdFinance::WorkspaceResolver.new(owner).household.accounts.create!(label: "Private", account_type: "checking", balance_cents: 100_00)

    patch "/api/v1/accounts/#{account.id}", params: { account: { balance: 0 } }, headers: headers(intruder, "intrude"), as: :json
    assert_response :not_found
    assert_equal 100_00, account.reload.balance_cents
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def headers(user, key)
    { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => key }
  end
end
