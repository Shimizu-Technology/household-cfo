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

  test "does not draft transfers, card payments or CD deposits as spending" do
    movements = [
      plaid_transaction(amount_cents: 100_000, name: "CD DEPOSIT .INITIAL.", primary_category: "TRANSFER_OUT", detailed_category: "TRANSFER_OUT_ACCOUNT_TRANSFER"),
      plaid_transaction(amount_cents: 207_850, name: "AUTOMATIC PAYMENT - THANK", primary_category: "LOAN_PAYMENTS", detailed_category: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"),
      plaid_transaction(amount_cents: 2_500, name: "CREDIT CARD 3333 PAYMENT", primary_category: "loan_payments", detailed_category: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"),
      plaid_transaction(amount_cents: 6_000, name: "ATM WITHDRAWAL", primary_category: "TRANSFER_OUT", detailed_category: "TRANSFER_OUT_WITHDRAWAL")
    ]

    assert_equal %w[transfer debt_payment debt_payment cash_withdrawal], movements.map(&:movement_type)
    assert movements.none?(&:counts_as_spending?)
    assert movements.none?(&:stageable?)
    assert_empty PlaidTransaction.where(id: movements.map(&:id)).stageable
    assert_no_difference("TransactionDraft.count") do
      error = assert_raises(PlaidIntegration::Error) do
        PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: movements.map(&:id)).call
      end
      assert_equal "Only unreviewed, posted expenses can be drafted", error.message
    end
  end

  test "keeps bank fees and interest charges as spending" do
    fee = plaid_transaction(amount_cents: 3_500, name: "OVERDRAFT FEE", primary_category: "BANK_FEES", detailed_category: "BANK_FEES_OVERDRAFT_FEES")
    interest = plaid_transaction(amount_cents: 1_200, name: "INTEREST CHARGE", primary_category: "BANK_FEES", detailed_category: "BANK_FEES_INTEREST_CHARGE")

    assert_equal %w[fee interest], [ fee, interest ].map(&:movement_type)
    result = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ fee.id, interest.id ]).call

    assert_equal 2, result.drafts.length
    assert result.drafts.all? { |draft| draft.budget_category.nil? }
  end

  test "leaves a ride share as needs category instead of guessing car insurance" do
    HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Car insurance", stack_key: "sinking_expected", monthly_amount: 100)
    transaction = plaid_transaction(
      amount_cents: 2_340,
      name: "Uber 063015 SF**POOL**",
      primary_category: "TRANSPORTATION",
      detailed_category: "TRANSPORTATION_TAXIS_AND_RIDE_SHARES"
    )

    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ transaction.id ]).call.drafts.first

    assert_nil draft.budget_category
    assert_equal "needs_review", draft.draft_payload.fetch("category_match_status")
    assert_equal "no_strong_match", draft.draft_payload.fetch("category_match_reason")
  end

  test "maps a Plaid fuel purchase to a fuel category, never to car insurance" do
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    manager.create_category!(name: "Car insurance", stack_key: "sinking_expected", monthly_amount: 100)
    gas = manager.create_category!(name: "Gas", stack_key: "discretionary", monthly_amount: 200)
    transaction = plaid_transaction(amount_cents: 4_500, name: "Chevron", primary_category: "TRANSPORTATION", detailed_category: "TRANSPORTATION_GAS")

    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ transaction.id ]).call.drafts.first

    assert_equal gas, draft.budget_category
  end

  test "uses Plaid fast-food taxonomy when a matching household category exists" do
    dining = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Dining out", stack_key: "discretionary", monthly_amount: 250)
    transaction = plaid_transaction(
      amount_cents: 1_200,
      name: "KFC",
      primary_category: "FOOD_AND_DRINK",
      detailed_category: "FOOD_AND_DRINK_FAST_FOOD"
    )

    result = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ transaction.id ]).call

    assert_equal dining, result.drafts.first.budget_category
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

  def plaid_transaction(amount_cents:, name:, pending: false, primary_category: nil, detailed_category: nil)
    @item.plaid_transactions.create!(
      plaid_account: @account,
      plaid_transaction_id: "transaction-#{SecureRandom.hex(5)}",
      name: name,
      occurred_on: Date.new(2026, 7, 10),
      amount_cents: amount_cents,
      pending: pending,
      primary_category: primary_category,
      detailed_category: detailed_category,
      source_fingerprint: SecureRandom.hex(32)
    )
  end
end
