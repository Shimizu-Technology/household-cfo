require "test_helper"

class HouseholdFinancialBoundaryTest < ActiveSupport::TestCase
  setup do
    @owner = create_user("boundary-owner-#{SecureRandom.hex(4)}@example.com")
    @other_owner = create_user("boundary-other-#{SecureRandom.hex(4)}@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@owner).household
    @other_household = HouseholdFinance::WorkspaceResolver.new(@other_owner).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household)
    @other_manager = HouseholdFinance::AnnualBudgetManager.new(@other_household)
    @category = @manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 300)
    @other_category = @other_manager.create_category!(name: "Other groceries", stack_key: "discretionary", monthly_amount: 200)
    @period = @manager.current_period_for(Date.current)
    @other_period = @other_manager.current_period_for(Date.current)
  end

  test "budget allocations cannot connect another household category" do
    allocation = BudgetAllocation.new(budget_period: @period, budget_category: @other_category, planned_amount_cents: 100, source: "manual")

    assert_not allocation.valid?
    assert_includes allocation.errors[:budget_category], "must belong to the budget period household"
  end

  test "posted transactions reject another household period and document import" do
    transaction = transaction_for(@household, @other_period)

    assert_not transaction.valid?
    assert_includes transaction.errors[:budget_period], "must belong to the transaction household"

    transaction.budget_period = @period
    transaction.source_import = document_import_for(@other_household, @other_owner)

    assert_not transaction.valid?
    assert_includes transaction.errors[:source_import], "must belong to the transaction household"
  end

  test "posted transaction splits reject another household category" do
    transaction = transaction_for(@household, @period)
    transaction.save!
    split = transaction.transaction_splits.build(budget_category: @other_category, amount_cents: 100)

    assert_not split.valid?
    assert_includes split.errors[:budget_category], "must belong to the transaction household"
  end

  test "pending transaction reviews reject every foreign household association" do
    other_transaction = transaction_for(@other_household, @other_period)
    other_transaction.save!
    other_import = document_import_for(@other_household, @other_owner)
    draft = draft_for(@household)

    {
      budget_category: @other_category,
      financial_document_import: other_import,
      confirmed_transaction: other_transaction,
      matched_transaction: other_transaction
    }.each do |association, record|
      draft.public_send("#{association}=", record)
      assert_not draft.valid?
      assert_includes draft.errors[association], "must belong to the transaction draft household"
      draft.public_send("#{association}=", nil)
    end
  end

  test "pending split categories and reconciliation matches cannot cross households" do
    draft = draft_for(@household)
    draft.save!
    split = draft.transaction_draft_splits.build(budget_category: @other_category, amount_cents: 100)

    assert_not split.valid?
    assert_includes split.errors[:budget_category], "must belong to the transaction draft household"

    other_transaction = transaction_for(@other_household, @other_period)
    other_transaction.save!
    match = draft.transaction_draft_matches.build(household_transaction: other_transaction, status: "proposed")

    assert_not match.valid?
    assert_includes match.errors[:household_transaction], "must belong to the transaction draft household"
  end

  test "bank transactions reject an account or pending review from another bank household" do
    item = plaid_item_for(@household, @owner)
    other_item = plaid_item_for(@other_household, @other_owner)
    account = item.plaid_accounts.create!(plaid_account_id: "account_#{SecureRandom.hex(5)}", name: "Checking", account_type: "depository")
    other_account = other_item.plaid_accounts.create!(plaid_account_id: "account_#{SecureRandom.hex(5)}", name: "Other checking", account_type: "depository")
    transaction = item.plaid_transactions.build(
      plaid_account: other_account,
      plaid_transaction_id: "transaction_#{SecureRandom.hex(5)}",
      name: "Market",
      occurred_on: Date.current,
      amount_cents: 100,
      source_fingerprint: "fingerprint_#{SecureRandom.hex(5)}",
      review_status: "unreviewed"
    )

    assert_not transaction.valid?
    assert_includes transaction.errors[:plaid_account], "must belong to the selected bank connection"

    other_draft = draft_for(@other_household)
    other_draft.save!
    transaction.plaid_account = account
    transaction.transaction_draft = other_draft

    assert_not transaction.valid?
    assert_includes transaction.errors[:transaction_draft], "must belong to the bank connection household"
  end

  test "document extraction results cannot point at another household applied record" do
    document_import = document_import_for(@household, @owner)
    other_expense = @other_household.expense_items.create!(label: "Other expense", stack_key: "discretionary", amount_cents: 100, cadence: "monthly")
    item = document_import.items.build(target_type: "expense_item", label: "Groceries", amount_cents: 100, applied_record: other_expense)

    assert_not item.valid?
    assert_includes item.errors[:applied_record], "must belong to the document import household"
  end

  test "Mia action drafts reject messages originating in another household conversation" do
    other_session = @other_household.chat_sessions.create!(user: @other_owner)
    other_message = other_session.chat_messages.create!(role: "user", content: "Change groceries")
    action = @household.mia_action_drafts.build(
      requested_by_user: @owner,
      source_chat_message: other_message,
      year: Date.current.year,
      status: "pending",
      draft_type: "budget_edit",
      title: "Change groceries",
      summary: "Review the groceries change"
    )

    assert_not action.valid?
    assert_includes action.errors[:source_chat_message], "must belong to the Mia action household"
  end

  private

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def transaction_for(household, period)
    household.household_transactions.build(
      budget_period: period,
      occurred_on: Date.current,
      merchant: "Market",
      total_amount_cents: 100,
      source_type: "manual_ui",
      status: "confirmed"
    )
  end

  def draft_for(household)
    household.transaction_drafts.build(
      occurred_on: Date.current,
      merchant: "Market",
      total_amount_cents: 100,
      source_type: "manual_ui",
      status: "pending"
    )
  end

  def document_import_for(household, user)
    household.financial_document_imports.create!(
      uploaded_by_user: user,
      document_kind: "statement",
      status: "needs_review",
      filename: "statement.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "test/statement-#{SecureRandom.hex(4)}.csv"
    )
  end

  def plaid_item_for(household, user)
    household.plaid_items.create!(
      connected_by_user: user,
      plaid_item_id: "item_#{SecureRandom.hex(5)}",
      environment: "sandbox",
      status: "active",
      consented_at: Time.current,
      consent_policy_version: "test",
      access_token_ciphertext: "encrypted-test-token"
    )
  end
end
