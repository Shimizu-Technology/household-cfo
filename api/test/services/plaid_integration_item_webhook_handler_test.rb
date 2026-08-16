require "test_helper"

class PlaidIntegrationItemWebhookHandlerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(clerk_id: "webhook_#{SecureRandom.hex(6)}", email: "plaid-webhook@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "webhook-item",
      access_token: "webhook-secret",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test"
    )
    @account = @item.plaid_accounts.create!(plaid_account_id: "webhook-account", name: "Checking", account_type: "depository")
  end

  test "marks login errors for update mode without storing Plaid's raw message" do
    call_handler("webhook_code" => "ERROR", "error" => { "error_code" => "ITEM_LOGIN_REQUIRED", "error_message" => "raw institution detail" })

    assert_equal "update_required", @item.reload.status
    assert_equal "ITEM_LOGIN_REQUIRED", @item.error_code
    assert_equal "This bank connection needs attention. Reconnect it to keep transactions up to date.", @item.error_message
    refute_includes @item.error_message, "raw institution detail"
  end

  test "marks pending disconnects for update mode" do
    call_handler("webhook_code" => "PENDING_DISCONNECT")

    assert_equal "update_required", @item.reload.status
    assert_equal "PENDING_DISCONNECT", @item.error_code
  end

  test "restores and synchronizes a repaired item" do
    @item.update!(status: "update_required", error_code: "ITEM_LOGIN_REQUIRED", error_message: "Reconnect")

    assert_enqueued_with(job: PlaidTransactionSyncJob, args: [ @item.id ]) do
      call_handler("webhook_code" => "LOGIN_REPAIRED")
    end

    assert_equal "active", @item.reload.status
    assert_nil @item.error_code
    assert_nil @item.error_message
  end

  test "deletes source data and requests update mode when an account permission is revoked" do
    pending_draft = @household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: "Revoked source row",
      total_amount_cents: 1_000,
      source_type: "plaid",
      status: "pending",
      confidence: 0.8
    )
    transaction = @item.plaid_transactions.create!(
      plaid_account: @account,
      transaction_draft: pending_draft,
      plaid_transaction_id: "revoked-transaction",
      name: "Revoked source row",
      occurred_on: Date.current,
      amount_cents: 1_000,
      source_fingerprint: "revoked-source-fingerprint"
    )

    call_handler("webhook_code" => "USER_ACCOUNT_REVOKED", "account_id" => @account.plaid_account_id)

    refute PlaidAccount.exists?(@account.id)
    refute PlaidTransaction.exists?(transaction.id)
    refute TransactionDraft.exists?(pending_draft.id)
    assert_equal "update_required", @item.reload.status
    assert_equal "USER_ACCOUNT_REVOKED", @item.error_code
  end

  test "preserves approved actuals and unrelated drafts when an account permission is revoked" do
    approved_draft = @household.transaction_drafts.create!(occurred_on: Date.current, merchant: "Approved source", total_amount_cents: 2_000, source_type: "plaid", status: "confirmed", confidence: 1)
    unrelated_draft = @household.transaction_drafts.create!(occurred_on: Date.current, merchant: "Other source", total_amount_cents: 3_000, source_type: "plaid", status: "pending", confidence: 0.8)
    @item.plaid_transactions.create!(plaid_account: @account, transaction_draft: approved_draft, plaid_transaction_id: "approved-revoked-transaction", name: "Approved source", occurred_on: Date.current, amount_cents: 2_000, source_fingerprint: SecureRandom.hex(32))

    call_handler("webhook_code" => "USER_ACCOUNT_REVOKED", "account_id" => @account.plaid_account_id)

    assert TransactionDraft.exists?(approved_draft.id)
    assert TransactionDraft.exists?(unrelated_draft.id)
  end

  test "requests update mode when Plaid detects new accounts" do
    call_handler("webhook_code" => "NEW_ACCOUNTS_AVAILABLE")

    assert_equal "update_required", @item.reload.status
    assert_equal "NEW_ACCOUNTS_AVAILABLE", @item.error_code
  end

  test "ignores webhook update acknowledgements" do
    assert_no_changes -> { @item.reload.attributes.slice("status", "error_code", "error_message") } do
      call_handler("webhook_code" => "WEBHOOK_UPDATE_ACKNOWLEDGED")
    end
  end

  private

  def call_handler(values)
    payload = { "webhook_type" => "ITEM", "item_id" => @item.plaid_item_id }.merge(values)
    PlaidIntegration::ItemWebhookHandler.new(item: @item, payload: payload).call
  end
end
