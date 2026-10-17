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
    assert_equal "initializing", serialized.dig("health", "state")
    refute_includes response.body, "server-access-token"
    refute serialized.key?("plaid_item_id")
    refute serialized.key?("access_token_ciphertext")
  end

  test "linked observation without a completed sync is not presented as newer" do
    @account.update!(account_subtype: "checking", current_balance_cents: 0)
    @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 0, balance_known: true, plaid_account: @account)

    get "/api/v1/plaid/items", headers: auth_headers(@user)

    assert_response :success
    observed = response.parsed_body.fetch("items").first.fetch("accounts").first
    assert_equal false, observed.fetch("observation_newer_than_saved")
    assert_equal 0, observed.fetch("canonical_balance_cents")
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
    assert_equal "needs_review", rows.first.fetch("trust_state")
    refute_includes response.body, "Private merchant"
    assert_equal({ "page" => 1, "per_page" => 50, "total" => 1, "has_more" => false }, payload.fetch("pagination"))
    assert_equal 1, payload.fetch("summary").fetch("needs_review_count")
    assert_equal 4_200, payload.fetch("summary").fetch("posted_outflow_cents")
    assert_equal Date.current.year, payload.dig("summary", "review_year")
  end

  test "not_spending view lists each loan payment and person transfers carry a note" do
    mortgage = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "spend-mortgage", name: "MORTGAGE PAYMENT", occurred_on: Date.new(2026, 7, 1), amount_cents: 150_000, pending: false, primary_category: "LOAN_PAYMENTS", detailed_category: "LOAN_PAYMENTS_MORTGAGE_PAYMENT", source_fingerprint: SecureRandom.hex(32))
    venmo = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "spend-venmo", name: "VENMO", occurred_on: Date.new(2026, 7, 2), amount_cents: 4_500, pending: false, primary_category: "TRANSFER_OUT", detailed_category: "TRANSFER_OUT_OTHER_TRANSFER_OUT", source_fingerprint: SecureRandom.hex(32))

    get "/api/v1/plaid/transactions", params: { view: "not_spending" }, headers: auth_headers(@user)
    assert_response :success
    assert_equal [ mortgage.id ], JSON.parse(response.body).fetch("transactions").map { |row| row.fetch("id") }

    get "/api/v1/plaid/transactions", params: { view: "needs_review" }, headers: auth_headers(@user)
    rows = JSON.parse(response.body).fetch("transactions").index_by { |row| row.fetch("id") }
    assert_equal PlaidTransaction::REVIEW_NOTE_TRANSFER_OR_PAYMENT, rows.fetch(venmo.id).fetch("review_note")
    assert rows.fetch(venmo.id).fetch("counts_as_spending")
    refute rows.key?(mortgage.id)
  end

  test "a confirmed draft stays confirmed if Plaid later recategorizes the row" do
    row = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "spend-recat", name: "Gym", occurred_on: Date.new(2026, 7, 3), amount_cents: 3_000, pending: false, primary_category: "PERSONAL_CARE", source_fingerprint: SecureRandom.hex(32))
    draft = @household.transaction_drafts.create!(occurred_on: row.occurred_on, merchant: "Gym", total_amount_cents: 3_000, source_type: "plaid", status: "confirmed")
    row.update!(transaction_draft: draft, review_status: "drafted", primary_category: "TRANSFER_OUT", detailed_category: "TRANSFER_OUT_ACCOUNT_TRANSFER")

    get "/api/v1/plaid/transactions", headers: auth_headers(@user)
    assert_equal "confirmed", JSON.parse(response.body).fetch("transactions").find { |r| r.fetch("id") == row.id }.fetch("trust_state")
  end

  test "transfers and card payments are listed as not counted as spending" do
    purchase = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "spend-purchase", name: "Island Market", occurred_on: Date.new(2026, 7, 10), amount_cents: 4_200, pending: false, primary_category: "FOOD_AND_DRINK", detailed_category: "FOOD_AND_DRINK_GROCERIES", source_fingerprint: SecureRandom.hex(32))
    payment = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "spend-card-payment", name: "CREDIT CARD 3333 PAYMENT", occurred_on: Date.new(2026, 7, 11), amount_cents: 2_500, pending: false, primary_category: "LOAN_PAYMENTS", detailed_category: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT", source_fingerprint: SecureRandom.hex(32))

    get "/api/v1/plaid/transactions", params: { review_year: 2026 }, headers: auth_headers(@user)

    assert_response :success
    payload = JSON.parse(response.body)
    rows = payload.fetch("transactions").index_by { |row| row.fetch("id") }
    assert_equal "not_spending", rows.fetch(payment.id).fetch("trust_state")
    assert_equal "debt_payment", rows.fetch(payment.id).fetch("movement_type")
    refute rows.fetch(payment.id).fetch("counts_as_spending")
    refute rows.fetch(payment.id).fetch("stageable")
    assert_equal "needs_review", rows.fetch(purchase.id).fetch("trust_state")
    assert_equal "purchase", rows.fetch(purchase.id).fetch("movement_type")
    summary = payload.fetch("summary")
    assert_equal 4_200, summary.fetch("posted_outflow_cents")
    assert_equal 1, summary.fetch("posted_outflow_count")
    assert_equal 1, summary.fetch("not_counted_as_spending_count")
    assert_equal 2_500, summary.fetch("not_counted_as_spending_cents")
    assert_equal 1, summary.fetch("needs_review_count")
    assert_equal 4_200, summary.fetch("needs_review_cents")

    get "/api/v1/plaid/transactions", params: { view: "needs_review" }, headers: auth_headers(@user)

    assert_equal [ purchase.id ], JSON.parse(response.body).fetch("transactions").map { |row| row.fetch("id") }
  end

  test "transaction summary reconciles all-history and selected-year review counts" do
    current = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "current-review", name: "Current purchase", occurred_on: Date.new(2026, 7, 10), amount_cents: 4_200, pending: false, source_fingerprint: SecureRandom.hex(32))
    @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "older-review", name: "Older purchase", occurred_on: Date.new(2025, 7, 10), amount_cents: 9_900, pending: false, source_fingerprint: SecureRandom.hex(32))

    get "/api/v1/plaid/transactions", params: { review_year: 2026 }, headers: auth_headers(@user)

    assert_response :success
    summary = JSON.parse(response.body).fetch("summary")
    assert_equal 2, summary.fetch("needs_review_count")
    assert_equal 2026, summary.fetch("review_year")
    assert_equal 1, summary.fetch("review_year_needs_review_count")
    assert_equal current.amount_cents, summary.fetch("review_year_needs_review_cents")
    assert_equal 1, summary.fetch("other_years_needs_review_count")
  end

  test "transaction listing filters by merchant search and household account" do
    matching = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "amazon-one", name: "AMAZON MARKETPLACE", merchant_name: "Amazon", occurred_on: Date.new(2026, 7, 10), amount_cents: 4_200, pending: false, source_fingerprint: SecureRandom.hex(32))
    other_account = @item.plaid_accounts.create!(plaid_account_id: "account-savings", name: "Savings", mask: "4321", account_type: "depository")
    other_transaction = @item.plaid_transactions.create!(plaid_account: other_account, plaid_transaction_id: "amazon-two", name: "Amazon transfer", occurred_on: Date.new(2026, 7, 11), amount_cents: 9_900, pending: false, source_fingerprint: SecureRandom.hex(32))
    confirm_plaid_transaction(matching)
    confirm_plaid_transaction(other_transaction)

    get "/api/v1/plaid/transactions", params: { query: "amazon", account_id: @account.id }, headers: auth_headers(@user)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal [ matching.id ], payload.fetch("transactions").map { |row| row.fetch("id") }
    assert_equal 1, payload.dig("pagination", "total")
    assert_equal 1, payload.dig("summary", "all_count")
    assert_equal 1, payload.dig("summary", "posted_outflow_count")
    assert_equal 4_200, payload.dig("summary", "posted_outflow_cents")
    assert_equal 1, payload.dig("summary", "confirmed_count")
    assert_equal 1, payload.dig("summary", "confirmed_actual_count")
    assert_equal 4_200, payload.dig("summary", "confirmed_cents")
    assert_equal 0, payload.dig("summary", "needs_review_count")
  end

  test "ignoring transactions is all-or-nothing for a mixed valid and invalid batch" do
    valid = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "ignore-valid", name: "Valid expense", occurred_on: Date.current, amount_cents: 4_200, pending: false, source_fingerprint: SecureRandom.hex(32))
    pending = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "ignore-pending", name: "Pending expense", occurred_on: Date.current, amount_cents: 2_100, pending: true, source_fingerprint: SecureRandom.hex(32))

    assert_no_difference -> { @household.household_audit_events.count } do
      post "/api/v1/plaid/transactions/ignore", params: { transaction_ids: [ valid.id, pending.id ] }, headers: auth_headers(@user), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "unreviewed", valid.reload.review_status
    assert_equal "unreviewed", pending.reload.review_status
  end

  test "ignoring a valid batch updates every row and records one audit event" do
    first = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "ignore-first", name: "First expense", occurred_on: Date.current, amount_cents: 4_200, pending: false, source_fingerprint: SecureRandom.hex(32))
    second = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "ignore-second", name: "Second expense", occurred_on: Date.current, amount_cents: 2_100, pending: false, source_fingerprint: SecureRandom.hex(32))

    assert_difference -> { @household.household_audit_events.count }, 1 do
      post "/api/v1/plaid/transactions/ignore", params: { transaction_ids: [ first.id, second.id ] }, headers: auth_headers(@user), as: :json
    end

    assert_response :success
    assert_equal 2, JSON.parse(response.body).fetch("ignored_count")
    assert_equal %w[ignored ignored], [ first.reload.review_status, second.reload.review_status ]
  end

  test "item review automation preference is explicit and household scoped" do
    patch "/api/v1/plaid/items/#{@item.id}", params: { auto_confirm_trusted_merchants: true }, headers: auth_headers(@user), as: :json

    assert_response :success
    assert @item.reload.auto_confirm_trusted_merchants?
    serialized = JSON.parse(response.body).fetch("items").find { |item| item.fetch("id") == @item.id }
    assert serialized.fetch("auto_confirm_trusted_merchants")
    event = @household.household_audit_events.order(:id).last
    assert_equal "plaid_item.review_preferences_updated", event.event_type
    assert_equal true, event.metadata.fetch("auto_confirm_trusted_merchants")
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

  def confirm_plaid_transaction(plaid_transaction)
    occurred_on = plaid_transaction.occurred_on
    budget_year = @household.budget_years.find_or_create_by!(year: occurred_on.year) { |year| year.status = "active" }
    period = budget_year.budget_periods.find_or_create_by!(starts_on: occurred_on.beginning_of_month) do |budget_period|
      budget_period.ends_on = occurred_on.end_of_month
      budget_period.status = "open"
    end
    actual = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: occurred_on,
      merchant: plaid_transaction.merchant_name.presence || plaid_transaction.name,
      total_amount_cents: plaid_transaction.amount_cents,
      source_type: "plaid",
      status: "confirmed"
    )
    draft = @household.transaction_drafts.create!(
      occurred_on: occurred_on,
      merchant: actual.merchant,
      total_amount_cents: actual.total_amount_cents,
      source_type: "plaid",
      status: "confirmed",
      confirmed_transaction: actual
    )
    plaid_transaction.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: plaid_transaction.source_fingerprint)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
