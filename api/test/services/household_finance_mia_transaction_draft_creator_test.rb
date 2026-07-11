require "test_helper"

class HouseholdFinanceMiaTransactionDraftCreatorTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "mia-draft-creator@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    @groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 850)
  end

  test "creates a pending review and suggests dining from the merchant" do
    result = HouseholdFinance::MiaTransactionDraftCreator.new(
      @household,
      command: {
        type: "create_transaction_draft",
        merchant: "Walkthrough Cafe Retest",
        amount: "12.35",
        occurred_on: "2026-07-10",
        category_id: 0,
        category_name: "",
        stack_key: "",
        splits: []
      },
      raw_input: "I spent $12.35 at Walkthrough Cafe Retest today."
    ).call

    assert result.success?
    draft = result.draft
    assert_equal "pending", draft.status
    assert_equal "Walkthrough Cafe Retest", draft.merchant
    assert_equal Date.new(2026, 7, 10), draft.occurred_on
    assert_equal 12_35, draft.total_amount_cents
    assert_equal @dining.id, draft.budget_category_id
    assert_equal [ [ @dining.id, 12_35 ] ], draft.transaction_draft_splits.pluck(:budget_category_id, :amount_cents)
    assert_equal "mia_structured_transaction_v1", draft.draft_payload.fetch("parser")
    assert_empty @household.household_transactions
  end

  test "creates validated explicit category splits" do
    result = HouseholdFinance::MiaTransactionDraftCreator.new(
      @household,
      command: {
        type: "create_transaction_draft",
        merchant: "Island Market Cafe",
        amount: "20.00",
        occurred_on: "2026-07-10",
        splits: [
          { category_id: @dining.id, category_name: "Dining Out", amount: "8.00" },
          { category_id: @groceries.id, category_name: "Groceries", amount: "12.00" }
        ]
      },
      raw_input: "I spent $20 at Island Market Cafe"
    ).call

    assert result.success?
    assert_equal [ [ @dining.id, 8_00 ], [ @groceries.id, 12_00 ] ], result.draft.transaction_draft_splits.order(:id).pluck(:budget_category_id, :amount_cents)
    assert_equal @dining.id, result.draft.budget_category_id
  end

  test "rejects invalid split totals without creating a draft" do
    assert_no_difference("TransactionDraft.count") do
      result = HouseholdFinance::MiaTransactionDraftCreator.new(
        @household,
        command: {
          merchant: "Island Market Cafe",
          amount: "20.00",
          occurred_on: "2026-07-10",
          splits: [ { category_id: @dining.id, category_name: "Dining Out", amount: "8.00" } ]
        },
        raw_input: "I spent $20 at Island Market Cafe"
      ).call

      refute result.success?
      assert_includes result.errors, "Transaction splits must equal transaction total"
    end
  end
end
