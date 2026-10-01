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

  test "keeps the pending-scope snapshot without reloading before the locked update" do
    editor = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: { draft_id: @draft.id, occurred_on: "2026-07-09" }
    )
    reload_flags = []
    original_snapshot = editor.method(:snapshot)
    editor.define_singleton_method(:snapshot) do |draft, reload: true|
      reload_flags << reload
      original_snapshot.call(draft, reload: reload)
    end

    result = editor.call

    assert result.success?
    assert_equal [ false, true ], reload_flags
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

  test "Mia amount correction preserves imported receipt split provenance" do
    @draft.update!(source_type: "receipt")
    split = @draft.transaction_draft_splits.sole
    split.update!(confidence: BigDecimal("0.77"), metadata: { "page" => 3, "bbox" => [ 10, 20, 30, 40 ] })

    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: { draft_id: @draft.id, amount: "15.25" },
      idempotency_key: "mia-receipt-amount"
    ).call

    assert result.success?, result.errors.to_sentence
    persisted = result.draft.transaction_draft_splits.sole
    assert_equal split.id, persisted.id
    assert_equal 15_25, persisted.amount_cents
    assert_equal BigDecimal("0.77"), persisted.confidence
    assert_equal({ "page" => 3, "bbox" => [ 10, 20, 30, 40 ] }, persisted.metadata)
    execution = @household.household_operation_executions.find_by!(idempotency_key: "mia-receipt-amount")
    assert_equal split.id, execution.after_snapshot.dig("splits", 0, "id")
    assert_equal "0.77", execution.after_snapshot.dig("splits", 0, "confidence")
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

  test "Mia explicit split correction preserves owned provenance and rejects a foreign split id" do
    @draft.update!(source_type: "receipt")
    split = @draft.transaction_draft_splits.sole
    split.update!(confidence: BigDecimal("0.77"), metadata: { "page" => 3 })
    foreign_draft = @household.transaction_drafts.create!(
      occurred_on: @draft.occurred_on,
      merchant: "Other receipt",
      total_amount_cents: 12_34,
      source_type: "receipt",
      status: "pending"
    )
    foreign_split = foreign_draft.transaction_draft_splits.create!(amount_cents: 12_34)

    rejected = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: { draft_id: @draft.id, splits: [ { id: foreign_split.id, category_id: @groceries.id, amount: "12.34" } ] },
      idempotency_key: "mia-foreign-receipt-split"
    ).call
    refute rejected.success?
    assert_includes rejected.response, "does not belong to this transaction review"

    result = HouseholdFinance::MiaTransactionDraftEditor.new(
      @household,
      command: { draft_id: @draft.id, splits: [ { id: split.id, category_id: @groceries.id, amount: "12.34" } ] },
      idempotency_key: "mia-owned-receipt-split"
    ).call

    assert result.success?, result.errors.to_sentence
    persisted = result.draft.transaction_draft_splits.sole
    assert_equal split.id, persisted.id
    assert_equal @groceries.id, persisted.budget_category_id
    assert_equal BigDecimal("0.77"), persisted.confidence
    assert_equal({ "page" => 3 }, persisted.metadata)
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
