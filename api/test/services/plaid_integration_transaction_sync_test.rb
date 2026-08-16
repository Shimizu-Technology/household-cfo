require "test_helper"
require "ostruct"

class PlaidIntegrationTransactionSyncTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "sync_#{SecureRandom.hex(6)}", email: "plaid-sync@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "sync-item", access_token: "sync-secret", institution_name: "Sandbox Bank", environment: "sandbox", consented_at: Time.current, consent_policy_version: "test")
  end

  test "normalizes accounts and all sync pages without storing a raw payload" do
    account = OpenStruct.new(
      account_id: "account-1", persistent_account_id: "persistent-1", name: "Checking", official_name: "Everyday Checking", mask: "4321", type: "depository", subtype: "checking",
      balances: OpenStruct.new(current: 123.45, available: 100.25, limit: nil, iso_currency_code: "USD")
    )
    first = OpenStruct.new(added: [ plaid_transaction("txn-1", 12.34) ], modified: [], removed: [], next_cursor: "cursor-1", has_more: true)
    second = OpenStruct.new(added: [ plaid_transaction("txn-2", -500) ], modified: [], removed: [], next_cursor: "cursor-2", has_more: false)
    fake = Object.new
    fake.define_singleton_method(:accounts_get) { |_request| OpenStruct.new(accounts: [ account ]) }
    pages = [ first, second ]
    fake.define_singleton_method(:transactions_sync) { |_request| pages.shift }

    singleton = class << PlaidIntegration::Client; self; end
    original = PlaidIntegration::Client.method(:safely)
    singleton.define_method(:safely) { |&block| block.call(fake) }
    begin
      PlaidIntegration::TransactionSync.new(@item).call
    ensure
      singleton.define_method(:safely, original)
    end

    assert_equal "cursor-2", @item.reload.sync_cursor
    assert_equal 12_345, @item.plaid_accounts.first.current_balance_cents
    assert_equal [ -50_000, 1_234 ], @item.plaid_transactions.order(:amount_cents).pluck(:amount_cents)
    assert_equal %w[txn-1 txn-2], @item.plaid_transactions.order(:plaid_transaction_id).pluck(:plaid_transaction_id)
    assert_equal 1, @household.transaction_drafts.pending.where(source_type: "plaid").count
    assert_equal "drafted", @item.plaid_transactions.find_by!(plaid_transaction_id: "txn-1").review_status
    assert_equal "unreviewed", @item.plaid_transactions.find_by!(plaid_transaction_id: "txn-2").review_status
    refute @item.plaid_transactions.column_names.any? { |name| name.include?("payload") || name.include?("location") }
  end

  test "keeps the cursor retryable and records a safe error when a transaction account is unavailable" do
    account = OpenStruct.new(
      account_id: "account-1", persistent_account_id: nil, name: "Checking", official_name: nil, mask: "4321", type: "depository", subtype: "checking",
      balances: OpenStruct.new(current: 100, available: 100, limit: nil, iso_currency_code: "USD")
    )
    transaction = plaid_transaction("txn-missing-account", 12.34)
    transaction.account_id = "account-not-returned"
    response = OpenStruct.new(added: [ transaction ], modified: [], removed: [], next_cursor: "must-not-advance", has_more: false)
    fake = Object.new
    fake.define_singleton_method(:accounts_get) { |_request| OpenStruct.new(accounts: [ account ]) }
    fake.define_singleton_method(:transactions_sync) { |_request| response }

    error = with_client(fake) do
      assert_raises(PlaidIntegration::Error) { PlaidIntegration::TransactionSync.new(@item).call }
    end

    assert_equal "PLAID_ACCOUNT_NOT_FOUND", error.code
    assert_nil @item.reload.sync_cursor
    assert_equal "error", @item.status
    assert_equal "PLAID_ACCOUNT_NOT_FOUND", @item.error_code
    assert_equal "Plaid returned a transaction for an account that is not available yet. Try syncing again.", @item.error_message
    assert_empty @item.plaid_transactions
  end

  private

  def with_client(fake)
    singleton = class << PlaidIntegration::Client; self; end
    original = PlaidIntegration::Client.method(:safely)
    singleton.define_method(:safely) { |&block| block.call(fake) }
    yield
  ensure
    singleton.define_method(:safely, original)
  end

  def plaid_transaction(id, amount)
    OpenStruct.new(
      transaction_id: id, account_id: "account-1", pending_transaction_id: nil, name: "Merchant", merchant_name: "Merchant", date: Date.new(2026, 7, 10), authorized_date: nil,
      amount: amount, pending: false, personal_finance_category: OpenStruct.new(primary: "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_GROCERIES"), payment_channel: "in store", iso_currency_code: "USD"
    )
  end
end
