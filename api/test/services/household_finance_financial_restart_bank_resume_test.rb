require "test_helper"

class HouseholdFinanceFinancialRestartBankResumeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "resume_#{SecureRandom.hex(6)}", email: "resume-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "item-#{SecureRandom.hex(6)}", environment: "sandbox", status: "active", consented_at: Time.current, consent_policy_version: "1", access_token_ciphertext: "synthetic-unused", auto_confirm_trusted_merchants: true, last_synced_at: 1.day.ago)
    @account = @item.plaid_accounts.create!(plaid_account_id: "account-#{SecureRandom.hex(6)}", name: "Synthetic checking", account_type: "depository", account_subtype: "checking", active: true, current_balance_cents: 100_000)
    @old = bank_transaction("old")
    @old_account = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 100_000, plaid_account: @account)
    @old_category = @household.budget_categories.create!(name: "Old market", stack_key: "discretionary", active: true, sort_order: 1)
    @household.merchant_category_rules.create!(budget_category: @old_category, merchant_pattern: "synthetic market", confidence: BigDecimal("0.99"), source: "user_confirmed", times_confirmed: 10)
    restart!
  end

  test "reviewed resume retains prior activity and requires freshly synced balance before linking new picture" do
    assert_not @item.current_financial_picture?
    assert_not @old.stageable?
    resume = HouseholdFinance::FinancialRestart::BankResume.new(@item, user: @user)
    assert_raises(ArgumentError) { resume.call(accepted: false, expected_item_financial_generation: 0) }
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { resume.call(accepted: true, expected_item_financial_generation: 9) }
    resume.call(accepted: true, expected_item_financial_generation: 0)
    assert_equal 1, @item.reload.financial_generation
    assert_not @item.auto_confirm_trusted_merchants?
    assert_nil @account.reload.account
    assert_not PlaidIntegration::AccountEligibility.new(@account).active_observation?
    assert_not @old.reload.stageable?
    assert_empty @item.plaid_transactions.stageable
    @old.update!(name: "Later correction of retained bank history")
    assert_equal 0, @old.reload.financial_generation
    newer = bank_transaction("new")
    assert_equal 1, newer.financial_generation
    assert newer.stageable?
    assert_equal [ newer.id ], @item.plaid_transactions.stageable.pluck(:id)
    assert_raises(PlaidIntegration::Error) do
      PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ @old.id ]).call
    end
    result = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ newer.id ]).call
    assert_equal 1, result.drafts.sole.financial_generation
    assert_nil result.drafts.sole.budget_category_id
    assert_nil PlaidIntegration::AutoConfirmer.new(@item).send(:trusted_rule, result.drafts.sole)
    assert_equal 1, @household.historical_merchant_category_rules.count
    assert_empty @household.merchant_category_rules
    @item.update!(last_synced_at: @item.financial_resumed_at + 1.second)
    assert_not PlaidIntegration::AccountEligibility.new(@account.reload).active_observation?
    @account.update!(financial_generation: @item.financial_generation, last_synced_at: @item.last_synced_at)
    assert PlaidIntegration::AccountEligibility.new(@account.reload).active_observation?
    current = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 200_000, plaid_account: @account)
    assert_equal current.id, @account.reload.account.id
    assert_equal 100_000, @old_account.reload.balance_cents
    assert_equal @account.id, @old_account.plaid_account_id
    resume.call(accepted: true, expected_item_financial_generation: 0)
    assert_equal 1, @household.household_audit_events.where(event_type: "plaid_item.financial_picture_resumed").count
  end

  test "a later restart invalidates older resume requests and bank row generations cannot be restamped" do
    resume = HouseholdFinance::FinancialRestart::BankResume.new(@item, user: @user)
    resume.call(accepted: true, expected_item_financial_generation: 0)
    restart!
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { resume.call(accepted: true, expected_item_financial_generation: 0) }
    assert_equal 1, @item.reload.financial_generation
    assert_not @item.current_financial_picture?
    assert_raises(ActiveRecord::StatementInvalid) do
      PlaidTransaction.transaction(requires_new: true) { @old.update_columns(financial_generation: 2) }
    end
  end

  test "disconnect can erase retained raw bank observations without changing saved financial snapshots" do
    PlaidIntegration::ItemDisconnector.new(@item, user: @user).send(:clear_local_data!)
    assert_equal "disconnected", @item.reload.status
    assert_nil @item.access_token_ciphertext
    assert_empty @item.plaid_transactions
    assert_empty @item.plaid_accounts
    assert_nil @old_account.reload.plaid_account_id
    assert_equal 100_000, @old_account.balance_cents
    assert_equal 0, @old_account.financial_generation
    assert_empty @household.reload.accounts
  end

  private
  def restart!
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    preview = flow.preview
    flow.apply(review_id: preview[:review][:id], confirmation: "START OVER")
  end

  def bank_transaction(label)
    @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "#{label}-#{SecureRandom.hex(6)}", name: "Synthetic market", merchant_name: "Synthetic market", occurred_on: Date.current, amount_cents: 1_000, pending: false, source_fingerprint: "#{label}-fingerprint")
  end
end
