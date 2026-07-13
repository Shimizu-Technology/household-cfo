require "test_helper"
require "base64"
require "ostruct"

class PlaidIntegrationTransactionSyncTest < ActiveSupport::TestCase
  setup do
    ENV["PLAID_DATA_ENCRYPTION_KEY"] = Base64.strict_encode64("s" * 32)
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
    refute @item.plaid_transactions.column_names.any? { |name| name.include?("payload") || name.include?("location") }
  end

  private

  def plaid_transaction(id, amount)
    OpenStruct.new(
      transaction_id: id, account_id: "account-1", pending_transaction_id: nil, name: "Merchant", merchant_name: "Merchant", date: Date.new(2026, 7, 10), authorized_date: nil,
      amount: amount, pending: false, personal_finance_category: OpenStruct.new(primary: "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_GROCERIES"), payment_channel: "in store", iso_currency_code: "USD"
    )
  end
end
