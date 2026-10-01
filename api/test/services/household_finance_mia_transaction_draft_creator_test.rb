require "test_helper"

class HouseholdFinanceMiaTransactionDraftCreatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "mia-draft-creator@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    @groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 850)
  end

  test "creates a pending review and suggests dining from the merchant" do
    result = HouseholdFinance::MiaTransactionDraftCreator.new(
      @household,
      user: @user,
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
      user: @user,
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
        user: @user,
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

  test "rejects non-expense money movements even when the model proposes an expense draft" do
    assert_no_difference("TransactionDraft.count") do
      result = HouseholdFinance::MiaTransactionDraftCreator.new(
        @household,
        user: @user,
        command: { merchant: "Visa", amount: "200", occurred_on: "2026-07-10", splits: [] },
        raw_input: "I paid $200 to my Visa credit card today"
      ).call

      refute result.success?
      assert_includes result.errors, "Only already incurred purchases can become transaction reviews"
    end
  end

  test "mixed money movements isolate only the explicitly reported purchase" do
    cases = [
      [ "I withdrew $100 and spent $20 at Pay-Less on groceries.", 2_000 ],
      [ "I paid my Visa $200 and spent $30 at Pay-Less.", 3_000 ]
    ]

    cases.each_with_index do |(message, expected_cents), index|
      result = HouseholdFinance::MiaTransactionDraftCreator.new(
        @household,
        user: @user,
        command: { merchant: "Visa", amount: index.zero? ? "100" : "200", occurred_on: "2026-07-10", splits: [] },
        raw_input: message,
        idempotency_key: "mixed-purchase-#{index}"
      ).call

      assert result.success?, result.errors.to_sentence
      assert_equal "Pay-Less", result.draft.merchant
      assert_equal expected_cents, result.draft.total_amount_cents
    end
    assert_equal [ 2_000, 3_000 ], @household.transaction_drafts.where(merchant: "Pay-Less").order(:id).pluck(:total_amount_cents)
  end
end
