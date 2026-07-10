require "test_helper"

class HouseholdFinanceMiaTransactionDraftEditorTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "mia-draft-editor@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 300)
    @groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 850)
    @draft = @household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 10),
      merchant: "Walkthrough Cafe",
      total_amount_cents: 12_34,
      budget_category: @dining,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $12.34 at Walkthrough Cafe today"
    )
    @draft.transaction_draft_splits.create!(budget_category: @dining, category_name: @dining.name, stack_key: @dining.stack_key, amount_cents: 12_34)
  end

  test "updates a pending draft date without changing actuals" do
    assert_no_difference("HouseholdTransaction.count") do
      result = HouseholdFinance::MiaTransactionDraftEditor.new(
        @household,
        command: { draft_id: @draft.id, occurred_on: "2026-07-09" }
      ).call

      assert result.success?
      assert_equal Date.new(2026, 7, 9), result.draft.occurred_on
      assert_equal "pending", result.draft.status
      assert_includes result.response, "date from Jul 10, 2026 to Jul 9, 2026"
      assert_includes result.response, "actuals did not change"
    end
  end

  test "updates merchant amount and category while keeping a single split valid" do
    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: {
        draft_id: @draft.id,
        merchant: "Neighborhood Cafe",
        amount: "15.25",
        category_id: @groceries.id,
        category_name: "Groceries"
      }
    ).call

    assert result.success?
    draft = result.draft
    assert_equal "Neighborhood Cafe", draft.merchant
    assert_equal 15_25, draft.total_amount_cents
    assert_equal @groceries.id, draft.budget_category_id
    assert_equal [ [ @groceries.id, 15_25 ] ], draft.transaction_draft_splits.pluck(:budget_category_id, :amount_cents)
    assert_includes result.response, "amount from $12.34 to $15.25"
    assert_includes result.response, "category from Dining Out to Groceries"
  end

  test "applies explicit category splits only when they equal the transaction total" do
    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: {
        draft_id: @draft.id,
        splits: [
          { category_id: @dining.id, category_name: "Dining Out", amount: "7.34" },
          { category_id: @groceries.id, category_name: "Groceries", amount: "5.00" }
        ]
      }
    ).call

    assert result.success?
    assert_equal [ 5_00, 7_34 ], result.draft.transaction_draft_splits.order(:amount_cents).pluck(:amount_cents)
    assert_includes result.response, "category splits"
  end

  test "rejects an amount-only correction for a multi-split draft without changing it" do
    @draft.transaction_draft_splits.destroy_all
    @draft.transaction_draft_splits.create!(budget_category: @dining, category_name: @dining.name, stack_key: @dining.stack_key, amount_cents: 7_34)
    @draft.transaction_draft_splits.create!(budget_category: @groceries, category_name: @groceries.name, stack_key: @groceries.stack_key, amount_cents: 5_00)

    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: { draft_id: @draft.id, amount: "15.25" }
    ).call

    refute result.success?
    assert_includes result.response, "tell me the new amount for each split"
    assert_equal 12_34, @draft.reload.total_amount_cents
    assert_equal [ 5_00, 7_34 ], @draft.transaction_draft_splits.order(:amount_cents).pluck(:amount_cents)
  end

  test "cannot edit a draft outside the household" do
    other_user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "other-mia-draft@example.com", role: "participant", invitation_status: "accepted")
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household

    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      other_household,
      command: { draft_id: @draft.id, occurred_on: "2026-07-09" }
    ).call

    refute result.success?
    assert_includes result.response, "could not find that pending transaction review"
    assert_equal Date.new(2026, 7, 10), @draft.reload.occurred_on
  end
end
