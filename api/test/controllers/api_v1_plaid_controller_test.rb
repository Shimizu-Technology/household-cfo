require "test_helper"

class ApiV1PlaidControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = create_user("plaid-controller@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = create_item(@household, @user, "item-one")
    @account = @item.plaid_accounts.create!(plaid_account_id: "account-one", name: "Checking", mask: "1234", account_type: "depository")
  end

  test "items endpoint never serializes Plaid identifiers or access credentials" do
    get "/api/v1/plaid/items", headers: auth_headers(@user)

    assert_response :success
    body = JSON.parse(response.body)
    serialized = body.fetch("items").first
    assert_equal "Sandbox Bank", serialized.fetch("institution_name")
    refute_includes response.body, "server-access-token"
    refute serialized.key?("plaid_item_id")
    refute serialized.key?("access_token_ciphertext")
  end

  test "link token endpoint requires explicit consent before calling Plaid" do
    post "/api/v1/plaid/items/link_token", params: { consent_accepted: false }, headers: auth_headers(@user), as: :json

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Review and accept the bank-data consent before connecting."
  end

  test "transaction listing is household scoped and exposes review boundaries" do
    transaction = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "txn-one", name: "Island Market", occurred_on: Date.new(2026, 7, 10), amount_cents: 4_200, pending: false, source_fingerprint: SecureRandom.hex(32))
    other_user = create_user("other-controller@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_item = create_item(other_household, other_user, "item-two")
    other_account = other_item.plaid_accounts.create!(plaid_account_id: "account-two", name: "Other", account_type: "depository")
    other_item.plaid_transactions.create!(plaid_account: other_account, plaid_transaction_id: "txn-two", name: "Private merchant", occurred_on: Date.new(2026, 7, 10), amount_cents: 9_900, pending: false, source_fingerprint: SecureRandom.hex(32))

    get "/api/v1/plaid/transactions", headers: auth_headers(@user)

    assert_response :success
    payload = JSON.parse(response.body)
    rows = payload.fetch("transactions")
    assert_equal [ transaction.id ], rows.map { |row| row.fetch("id") }
    assert rows.first.fetch("stageable")
    assert_equal "outflow", rows.first.fetch("direction")
    refute_includes response.body, "Private merchant"
    assert_equal({ "page" => 1, "per_page" => 50, "total" => 1, "has_more" => false }, payload.fetch("pagination"))
  end

  test "manual sync enqueues background work instead of blocking the request" do
    assert_enqueued_with(job: PlaidTransactionSyncJob, args: [ @item.id ]) do
      post "/api/v1/plaid/items/#{@item.id}/sync", headers: auth_headers(@user), as: :json
    end

    assert_response :accepted
  end

  test "manual sync does not enqueue another household's item" do
    other_user = create_user("other-sync-controller@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_item = create_item(other_household, other_user, "other-sync-item")

    assert_no_enqueued_jobs do
      post "/api/v1/plaid/items/#{other_item.id}/sync", headers: auth_headers(@user), as: :json
    end

    assert_response :not_found
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def create_item(household, user, item_id)
    household.plaid_items.create!(
      connected_by_user: user,
      plaid_item_id: item_id,
      access_token: "server-access-token-#{item_id}",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
