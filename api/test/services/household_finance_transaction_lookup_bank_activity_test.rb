require "test_helper"

class HouseholdFinanceTransactionLookupBankActivityTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "bank_lookup_#{SecureRandom.hex(6)}", email: "bank-lookup@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Shopping", stack_key: "discretionary", monthly_amount: 300)
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "lookup-item", access_token: "lookup-secret", institution_name: "Sandbox Bank", environment: "sandbox", consented_at: Time.current, consent_policy_version: "test")
    @account = @item.plaid_accounts.create!(plaid_account_id: "lookup-account", name: "Checking", account_type: "depository")
  end

  test "merchant answers separate bank observed, confirmed, review, and bank pending activity" do
    confirmed_source = plaid_transaction("confirmed-amazon", 7_227)
    plaid_transaction("review-amazon", 1_000)
    plaid_transaction("pending-amazon", 500, pending: true)

    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ confirmed_source.id ]).call.drafts.sole
    result = HouseholdFinance::TransactionDraftConfirmer.new(draft).call
    assert result.success?

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "How much did I spend at Amazon this month?",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "2 posted Amazon transactions totaling $82.27"
    assert_includes answer, "1 confirmed Amazon transaction totaling $72.27"
    assert_includes answer, "1 posted Amazon transaction totaling $10 still needs household review"
    assert_includes answer, "1 bank-pending Amazon transaction totaling $5"
  end

  test "across synced bank activity uses all available history" do
    plaid_transaction("august-amazon", 1_000)
    plaid_transaction("july-amazon", 2_000, occurred_on: Date.new(2026, 7, 24))

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "Across my synced bank activity, how many Amazon transactions are there and what do they total?",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "For all available bank history"
    assert_includes answer, "2 posted Amazon transactions totaling $30"
  end

  private

  def plaid_transaction(id, amount_cents, pending: false, occurred_on: Date.new(2026, 8, 14))
    @item.plaid_transactions.create!(
      plaid_account: @account,
      plaid_transaction_id: id,
      name: "Amazon",
      merchant_name: "Amazon",
      occurred_on: occurred_on,
      amount_cents: amount_cents,
      pending: pending,
      primary_category: "GENERAL_MERCHANDISE",
      source_fingerprint: SecureRandom.hex(32)
    )
  end
end
