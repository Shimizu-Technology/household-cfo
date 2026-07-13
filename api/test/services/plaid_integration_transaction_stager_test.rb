require "test_helper"

class PlaidIntegrationTransactionStagerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "plaid_#{SecureRandom.hex(6)}", email: "plaid-review@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 850)
    @item = @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "item-#{SecureRandom.hex(4)}",
      access_token: "access-sandbox-secret",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: PlaidIntegration::Configuration::CONSENT_POLICY_VERSION
    )
    @account = @item.plaid_accounts.create!(plaid_account_id: "account-#{SecureRandom.hex(4)}", name: "Checking", mask: "1234", account_type: "depository")
  end

  test "encrypts Plaid access tokens at rest" do
    refute_includes @item.access_token_ciphertext, "access-sandbox-secret"
    assert_equal "access-sandbox-secret", @item.access_token
  end

  test "stages a posted outflow as a pending draft without changing actuals" do
    transaction = plaid_transaction(amount_cents: 8_542, name: "Pay-Less Supermarket")

    assert_no_difference("HouseholdTransaction.count") do
      result = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ transaction.id ]).call
      assert_equal 1, result.drafts.length
    end

    draft = transaction.reload.transaction_draft
    assert_equal "pending", draft.status
    assert_equal "plaid", draft.source_type
    assert_equal @category, draft.budget_category
    assert_equal 8_542, draft.transaction_draft_splits.sum(:amount_cents)
    assert_equal "drafted", transaction.review_status
    assert_equal "plaid_transaction.drafted", @household.household_audit_events.order(:id).last.event_type
  end

  test "does not stage pending charges or money in" do
    pending = plaid_transaction(amount_cents: 2_000, name: "Pending cafe", pending: true)
    income = plaid_transaction(amount_cents: -200_000, name: "Payroll")

    assert_no_difference("TransactionDraft.count") do
      error = assert_raises(PlaidIntegration::Error) do
        PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ pending.id ]).call
      end
      assert_equal "Only unreviewed, posted expenses can be drafted", error.message
    end
    refute income.stageable?
  end

  test "cannot stage another household's bank transaction" do
    transaction = plaid_transaction(amount_cents: 1_000, name: "Other household")
    other_user = User.create!(clerk_id: "other_#{SecureRandom.hex(6)}", email: "other-plaid@example.com", role: "participant", invitation_status: "accepted")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household

    error = assert_raises(PlaidIntegration::Error) do
      PlaidIntegration::TransactionStager.new(household: other_household, user: other_user, transaction_ids: [ transaction.id ]).call
    end
    assert_equal "One or more bank transactions were not found", error.message
  end

  private

  def plaid_transaction(amount_cents:, name:, pending: false)
    @item.plaid_transactions.create!(
      plaid_account: @account,
      plaid_transaction_id: "transaction-#{SecureRandom.hex(5)}",
      name: name,
      occurred_on: Date.new(2026, 7, 10),
      amount_cents: amount_cents,
      pending: pending,
      source_fingerprint: SecureRandom.hex(32)
    )
  end
end
