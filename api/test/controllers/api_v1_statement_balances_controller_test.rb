require "test_helper"

class ApiV1StatementBalancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "statement-balances@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "lists no offers without approved statements and reports the financial picture" do
    get "/api/v1/statement_balances", headers: auth
    assert_response :success
    assert_equal [], response.parsed_body.fetch("offers")
    assert_equal @household.reload.financial_generation.to_s, response.headers["X-Financial-Generation"]
  end

  test "an approval from an earlier financial picture is refused and changes nothing" do
    account = @household.accounts.create!(label: "Checking ····4410", account_type: "checking", balance_cents: 100_00)
    @household.update!(financial_generation: 1)
    post "/api/v1/statement_balances/1/apply", params: { kind: "account", target: account.id.to_s, offer_key: "a" * 64 },
      headers: auth.merge("Idempotency-Key" => "stale-generation"), as: :json
    assert_response :conflict
    assert_equal "financial_generation_stale", response.parsed_body["code"]
    assert_equal 100_00, account.reload.balance_cents
  end

  test "an offer that is not current is refused without changing the account" do
    account = @household.accounts.create!(label: "Checking ····4410", account_type: "checking", balance_cents: 100_00)
    post "/api/v1/statement_balances/999999/apply", params: { kind: "account", target: account.id.to_s, offer_key: "a" * 64 },
      headers: auth.merge("Idempotency-Key" => "no-offer"), as: :json
    assert_response :conflict
    assert_equal "stale_review", response.parsed_body["code"]
    assert_equal 100_00, account.reload.balance_cents
  end

  private

  def auth = { "Authorization" => "Bearer test_token_#{@user.id}" }
end
