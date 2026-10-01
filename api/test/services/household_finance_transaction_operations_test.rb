require "test_helper"

class HouseholdFinanceTransactionOperationsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(clerk_id: "transaction_ops_#{SecureRandom.hex(8)}", email: "transaction-ops-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 600)
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "manual create is pending, audited, idempotent, and leaves actuals unchanged" do
    travel_to Date.new(2026, 10, 1) do
      input = { occurred_on: "2026-09-30", merchant: "Village Market", amount: "42.17", budget_category_id: @category.id, source_type: "manual_ui" }
      first = @runner.run(operation_key: "transaction.draft.create", input: input, idempotency_key: "manual-create")
      replay = @runner.run(operation_key: "transaction.draft.create", input: input, idempotency_key: "manual-create")

      draft = first.subject.reload
      assert replay.replayed?
      assert_equal draft, replay.subject
      assert_equal "pending", draft.status
      assert_equal "manual_ui", draft.source_type
      assert_equal [ [ @category.id, 4_217 ] ], draft.transaction_draft_splits.pluck(:budget_category_id, :amount_cents)
      assert_empty @household.household_transactions
      assert_equal 1, @household.household_operation_executions.where(idempotency_key: "manual-create").count
      audit = @household.household_audit_events.find_by!(event_type: "household_operation.executed")
      assert_equal "transaction.draft.create", audit.metadata.fetch("operation_key")
    end
  end

  test "unknown merchants stay uncategorized and future dates fail closed" do
    travel_to Date.new(2026, 10, 1) do
      unknown = @runner.run(
        operation_key: "transaction.draft.create",
        input: { occurred_on: "2026-10-01", merchant: "ZXQ Unseen Vendor", amount: "9.99", source_type: "manual_ui" },
        idempotency_key: "unknown"
      ).subject
      assert_nil unknown.budget_category_id
      assert_nil unknown.transaction_draft_splits.sole.budget_category_id

      error = assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.create",
          input: { occurred_on: "2026-10-02", merchant: "Tomorrow Shop", amount: "5", source_type: "manual_ui" },
          idempotency_key: "future"
        )
      end
      assert_includes error.message, "cannot be in the future"
      assert_nil @household.transaction_drafts.find_by(merchant: "Tomorrow Shop")
    end
  end

  test "update validates split totals and household categories before changing the review" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("update-source")
      other_user = User.create!(clerk_id: "other_#{SecureRandom.hex(8)}", email: "other-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
      other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
      other_category = HouseholdFinance::AnnualBudgetManager.new(other_household, year: 2026).create_category!(name: "Other", stack_key: "discretionary", monthly_amount: 50)

      assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: { draft_id: draft.id, amount: "50", source_type: "manual_ui", splits: [ { budget_category_id: @category.id, amount: "10" } ] },
          idempotency_key: "bad-splits"
        )
      end
      assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: { draft_id: draft.id, budget_category_id: other_category.id, source_type: "manual_ui" },
          idempotency_key: "foreign-category"
        )
      end
      assert_equal [ "Village Market", 4_217, @category.id ], draft.reload.values_at(:merchant, :total_amount_cents, :budget_category_id)

      result = @runner.run(
        operation_key: "transaction.draft.update",
        input: { draft_id: draft.id, merchant: "Village Market Guam", amount: "50", source_type: "manual_ui" },
        idempotency_key: "valid-update"
      )
      assert_equal [ "Village Market Guam", 5_000 ], result.subject.reload.values_at(:merchant, :total_amount_cents)
      assert_empty @household.household_transactions

      date_input = { draft_id: draft.id, occurred_on: "2025-12-31", source_type: "manual_ui" }
      @runner.run(operation_key: "transaction.draft.update", input: date_input, idempotency_key: "date-update")
      date_replay = @runner.run(operation_key: "transaction.draft.update", input: date_input, idempotency_key: "date-update")
      assert date_replay.replayed?
      assert_equal Date.new(2025, 12, 31), draft.reload.occurred_on

      future_error = assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: { draft_id: draft.id, occurred_on: "2026-10-02", source_type: "manual_ui" },
          idempotency_key: "future-update"
        )
      end
      assert_includes future_error.message, "cannot be in the future"
    end
  end

  test "single and bulk ignore are idempotent and atomic without posting actuals" do
    travel_to Date.new(2026, 10, 1) do
      first = create_draft("first")
      second = create_draft("second", merchant: "Second Market")
      @runner.run(operation_key: "transaction.draft.ignore", input: { draft_id: first.id, source_type: "manual_ui" }, idempotency_key: "ignore-one")
      replay = @runner.run(operation_key: "transaction.draft.ignore", input: { draft_id: first.id, source_type: "manual_ui" }, idempotency_key: "ignore-one")
      assert replay.replayed?
      assert_equal "ignored", first.reload.status

      @runner.run(
        operation_key: "transaction.drafts.bulk_ignore",
        input: { draft_ids: [ second.id ], source_type: "manual_ui", year: 2026 },
        idempotency_key: "ignore-rest"
      )
      assert_equal "ignored", second.reload.status
      assert_empty @household.household_transactions
    end
  end

  test "receipt edits preserve the existing split id and server extraction provenance" do
    travel_to Date.new(2026, 10, 1) do
      draft = @household.transaction_drafts.create!(
        occurred_on: Date.new(2026, 9, 28), merchant: "Extracted Market", total_amount_cents: 4_217,
        budget_category: @category, source_type: "receipt", status: "pending", raw_input: "Receipt upload"
      )
      split = draft.transaction_draft_splits.create!(
        budget_category: @category, amount_cents: 4_217, category_name: @category.name,
        confidence: BigDecimal("0.87"), metadata: { "page" => 2, "bbox" => [ 1, 2, 3, 4 ] }
      )

      result = @runner.run(
        operation_key: "transaction.draft.update",
        input: {
          draft_id: draft.id, merchant: "Extracted Market Guam", occurred_on: "2026-09-29", source_type: "manual_ui",
          splits: [ { id: split.id, amount: "42.17", budget_category_id: @category.id, confidence: "0.01", metadata: { "page" => 99 } } ]
        },
        idempotency_key: "receipt-provenance"
      )

      persisted = result.subject.transaction_draft_splits.sole
      assert_equal split.id, persisted.id
      assert_equal BigDecimal("0.87"), persisted.confidence
      assert_equal({ "page" => 2, "bbox" => [ 1, 2, 3, 4 ] }, persisted.metadata)
      assert_equal "Extracted Market Guam", result.subject.merchant
      execution = result.execution.reload
      assert_equal "0.87", execution.before_snapshot.dig("splits", 0, "confidence")
      assert_equal({ "page" => 2, "bbox" => [ 1, 2, 3, 4 ] }, execution.after_snapshot.dig("splits", 0, "metadata"))
    end
  end

  test "statement category edits preserve multi-split granularity and reject foreign split ids" do
    travel_to Date.new(2026, 10, 1) do
      dining = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 200)
      draft = @household.transaction_drafts.create!(
        occurred_on: Date.new(2026, 9, 28), merchant: "Statement Store", total_amount_cents: 5_000,
        budget_category: @category, source_type: "statement", status: "pending", raw_input: "Statement row"
      )
      first = draft.transaction_draft_splits.create!(budget_category: @category, amount_cents: 3_000, confidence: 0.78, metadata: { "row" => 4 })
      second = draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 2_000, confidence: 0.66, metadata: { "row" => 5 })

      error = assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: { draft_id: draft.id, budget_category_id: dining.id, source_type: "manual_ui" },
          idempotency_key: "multi-collapse"
        )
      end
      assert_includes error.message, "Edit each split category"
      assert_equal [ [ first.id, 3_000 ], [ second.id, 2_000 ] ], draft.reload.transaction_draft_splits.order(:id).pluck(:id, :amount_cents)

      other = create_draft("foreign-split").transaction_draft_splits.sole
      assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: { draft_id: draft.id, source_type: "manual_ui", splits: [ { id: other.id, amount: "30", budget_category_id: dining.id }, { id: second.id, amount: "20", budget_category_id: dining.id } ] },
          idempotency_key: "foreign-split-update"
        )
      end

      @runner.run(
        operation_key: "transaction.draft.update",
        input: {
          draft_id: draft.id, source_type: "manual_ui",
          splits: [
            { id: first.id, amount: "30", budget_category_id: dining.id },
            { id: second.id, amount: "20", budget_category_id: dining.id }
          ]
        },
        idempotency_key: "multi-category-update"
      )
      persisted = draft.reload.transaction_draft_splits.order(:id).to_a
      assert_equal [ first.id, second.id ], persisted.map(&:id)
      assert_equal [ 3_000, 2_000 ], persisted.map(&:amount_cents)
      assert_equal [ dining.id, dining.id ], persisted.map(&:budget_category_id)
      assert_equal [ { "row" => 4 }, { "row" => 5 } ], persisted.map(&:metadata)
      assert_equal [ BigDecimal("0.78"), BigDecimal("0.66") ], persisted.map(&:confidence)
    end
  end

  private

  def create_draft(key, merchant: "Village Market")
    @runner.run(
      operation_key: "transaction.draft.create",
      input: { occurred_on: "2026-09-30", merchant: merchant, amount: "42.17", budget_category_id: @category.id, source_type: "manual_ui" },
      idempotency_key: key
    ).subject
  end
end
