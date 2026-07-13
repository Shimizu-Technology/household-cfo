require "test_helper"
require "base64"

class PlaidIntegrationItemDisconnectorTest < ActiveSupport::TestCase
  setup do
    ENV["PLAID_DATA_ENCRYPTION_KEY"] = Base64.strict_encode64("d" * 32)
    @user = User.create!(clerk_id: "disconnect_#{SecureRandom.hex(6)}", email: "plaid-disconnect@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "disconnect-item", access_token: "remove-me", institution_name: "Sandbox Bank", environment: "sandbox", consented_at: Time.current, consent_policy_version: "test")
    @account = @item.plaid_accounts.create!(plaid_account_id: "disconnect-account", name: "Checking", account_type: "depository")
    @draft = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 7, 10), merchant: "Reviewed merchant", total_amount_cents: 2_500, source_type: "plaid", status: "pending", confidence: 0.8, draft_payload: { parser: "plaid_transactions_sync_v1" })
    @item.plaid_transactions.create!(plaid_account: @account, transaction_draft: @draft, plaid_transaction_id: "disconnect-transaction", name: "Reviewed merchant", occurred_on: Date.new(2026, 7, 10), amount_cents: 2_500, pending: false, review_status: "drafted", source_fingerprint: SecureRandom.hex(32), drafted_source_fingerprint: SecureRandom.hex(32))
  end

  test "removes the Plaid Item before clearing source data and keeps supervised drafts" do
    removed_token = nil
    fake = Object.new
    fake.define_singleton_method(:item_remove) { |request| removed_token = request.access_token }

    with_client(fake) { PlaidIntegration::ItemDisconnector.new(@item, user: @user).call }

    assert_equal "remove-me", removed_token
    assert_equal "disconnected", @item.reload.status
    assert_nil @item.access_token_ciphertext
    assert_empty @item.plaid_accounts
    assert_empty @item.plaid_transactions
    assert @draft.reload.persisted?
    assert_equal "plaid_item.disconnected", @household.household_audit_events.order(:id).last.event_type
  end

  test "keeps the encrypted token and source data when Plaid removal fails" do
    singleton = class << PlaidIntegration::Client; self; end
    original = PlaidIntegration::Client.method(:safely)
    singleton.define_method(:safely) { |_args = nil, &_block| raise PlaidIntegration::Error, "Plaid could not complete that request" }

    assert_raises(PlaidIntegration::Error) { PlaidIntegration::ItemDisconnector.new(@item, user: @user).call }
    assert_equal "active", @item.reload.status
    assert_equal "remove-me", @item.access_token
    assert_equal 1, @item.plaid_transactions.count
  ensure
    singleton.define_method(:safely, original)
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
end
