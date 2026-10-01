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

  test "confirm and reopen are audited idempotent operations" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("confirm-source")
      input = { draft_id: draft.id, source_type: "manual_ui" }

      assert_difference("HouseholdTransaction.count", 1) do
        first = @runner.run(operation_key: "transaction.draft.confirm", input: input, idempotency_key: "confirm-one")
        replay = @runner.run(operation_key: "transaction.draft.confirm", input: input, idempotency_key: "confirm-one")
        assert replay.replayed?
        assert_equal first.subject.id, replay.subject.id
      end
      assert_equal "confirmed", draft.reload.status
      transaction = draft.confirmed_transaction

      reopen = @runner.run(operation_key: "transaction.draft.reopen", input: input, idempotency_key: "reopen-one")
      replay = @runner.run(operation_key: "transaction.draft.reopen", input: input, idempotency_key: "reopen-one")
      assert replay.replayed?
      assert_equal reopen.subject.id, replay.subject.id
      assert_equal "pending", draft.reload.status
      assert_equal "ignored", transaction.reload.status
      assert_equal 2, @household.household_operation_executions.where(idempotency_key: %w[confirm-one reopen-one]).count
      reopen_execution = @household.household_operation_executions.find_by!(idempotency_key: "reopen-one")
      assert_equal "confirmed", reopen_execution.after_snapshot.fetch("reopened_from_status")
      assert_equal transaction.id, reopen_execution.after_snapshot.dig("transaction", "id")
      assert_equal "ignored", reopen_execution.after_snapshot.dig("transaction", "status")
      assert_equal 4_217, reopen_execution.after_snapshot.dig("transaction", "total_amount_cents")
      assert_equal [ 4_217 ], reopen_execution.after_snapshot.dig("transaction", "splits").map { |split| split.fetch("amount_cents") }
    end
  end

  test "match is audited and replays the exact accepted candidate" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("match-source")
      period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(draft.occurred_on)
      transaction = @household.household_transactions.create!(
        budget_period: period, occurred_on: draft.occurred_on, merchant: draft.merchant,
        total_amount_cents: draft.total_amount_cents, source_type: "manual_ui", status: "confirmed"
      )
      transaction.transaction_splits.create!(budget_category: @category, amount_cents: draft.total_amount_cents)
      candidate = draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.99, status: "proposed", match_reason: "same purchase")
      input = { draft_id: draft.id, match_id: candidate.id, source_type: "manual_ui" }

      @runner.run(operation_key: "transaction.draft.match", input: input, idempotency_key: "match-one")
      replay = @runner.run(operation_key: "transaction.draft.match", input: input, idempotency_key: "match-one")

      assert replay.replayed?
      assert_equal "matched", draft.reload.status
      assert_equal transaction.id, draft.matched_transaction_id
      assert_equal "accepted", candidate.reload.status
      assert_equal "transaction.draft.match", replay.execution.operation_key

      reopened = @runner.run(operation_key: "transaction.draft.reopen", input: input, idempotency_key: "reopen-match")
      assert_equal "pending", draft.reload.status
      assert_nil draft.matched_transaction_id
      assert_equal "proposed", candidate.reload.status
      assert_equal "confirmed", transaction.reload.status
      assert_equal "matched", reopened.execution.after_snapshot.fetch("reopened_from_status")
      assert_equal transaction.id, reopened.execution.after_snapshot.dig("transaction", "id")
      assert_equal "confirmed", reopened.execution.after_snapshot.dig("transaction", "status")
      assert_equal draft.total_amount_cents, reopened.execution.after_snapshot.dig("transaction", "total_amount_cents")
      assert_equal "proposed", reopened.execution.after_snapshot.fetch("matches").sole.fetch("status")
    end
  end

  test "matched reopen rolls back when the linked actual changes" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("broken-matched-reopen-source")
      period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(draft.occurred_on)
      transaction = @household.household_transactions.create!(
        budget_period: period, occurred_on: draft.occurred_on, merchant: draft.merchant,
        total_amount_cents: draft.total_amount_cents, source_type: "manual_ui", status: "confirmed"
      )
      transaction.transaction_splits.create!(budget_category: @category, amount_cents: draft.total_amount_cents)
      match = draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.99, status: "proposed", match_reason: "same purchase")
      match_input = { draft_id: draft.id, match_id: match.id, source_type: "manual_ui" }
      @runner.run(operation_key: "transaction.draft.match", input: match_input, idempotency_key: "match-before-broken-reopen")
      reopen_input = { draft_id: draft.id, source_type: "manual_ui" }
      fake_factory = lambda do |target|
        Object.new.tap do |fake|
          fake.define_singleton_method(:call) do
            target.matched_transaction.update!(status: "ignored")
            target.transaction_draft_matches.update_all(status: "proposed", updated_at: Time.current)
            target.update!(status: "pending", matched_transaction: nil)
            HouseholdFinance::TransactionDraftReopener::Result.new(success: true, draft: target.reload, errors: [])
          end
        end
      end

      singleton = HouseholdFinance::TransactionDraftReopener.singleton_class
      original_new = singleton.instance_method(:new)
      singleton.define_method(:new, &fake_factory)
      error = assert_raises(ArgumentError) do
        begin
          @runner.run(operation_key: "transaction.draft.reopen", input: reopen_input, idempotency_key: "broken-matched-reopen")
        ensure
          singleton.define_method(:new, original_new)
        end
      end

      assert_includes error.message, "did not match the requested change"
      assert_equal "matched", draft.reload.status
      assert_equal transaction.id, draft.matched_transaction_id
      assert_equal "confirmed", transaction.reload.status
      assert_equal "accepted", match.reload.status
      assert_nil @household.household_operation_executions.find_by(idempotency_key: "broken-matched-reopen")
    end
  end

  test "ignored reopen records an explicit no-actual terminal state" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("ignored-reopen-source")
      input = { draft_id: draft.id, source_type: "manual_ui" }
      @runner.run(operation_key: "transaction.draft.ignore", input: input, idempotency_key: "ignore-before-reopen")

      reopened = @runner.run(operation_key: "transaction.draft.reopen", input: input, idempotency_key: "reopen-ignored")

      assert_equal "pending", draft.reload.status
      assert_equal "ignored", reopened.execution.after_snapshot.fetch("reopened_from_status")
      assert_nil reopened.execution.after_snapshot.fetch("transaction")
      assert_nil reopened.execution.after_snapshot.dig("draft", "confirmed_transaction_id")
      assert_nil reopened.execution.after_snapshot.dig("draft", "matched_transaction_id")
    end
  end

  test "reopen rolls back when the confirmed actual is not ignored" do
    travel_to Date.new(2026, 10, 1) do
      draft = create_draft("broken-reopen-source")
      input = { draft_id: draft.id, source_type: "manual_ui" }
      @runner.run(operation_key: "transaction.draft.confirm", input: input, idempotency_key: "confirm-before-broken-reopen")
      transaction = draft.reload.confirmed_transaction
      fake_factory = lambda do |target|
        Object.new.tap do |fake|
          fake.define_singleton_method(:call) do
            target.update!(status: "pending", confirmed_transaction: nil, matched_transaction: nil)
            HouseholdFinance::TransactionDraftReopener::Result.new(success: true, draft: target.reload, errors: [])
          end
        end
      end

      singleton = HouseholdFinance::TransactionDraftReopener.singleton_class
      original_new = singleton.instance_method(:new)
      singleton.define_method(:new, &fake_factory)
      error = assert_raises(ArgumentError) do
        begin
          @runner.run(operation_key: "transaction.draft.reopen", input: input, idempotency_key: "broken-reopen")
        ensure
          singleton.define_method(:new, original_new)
        end
      end

      assert_includes error.message, "did not match the requested change"
      assert_equal "confirmed", draft.reload.status
      assert_equal transaction.id, draft.confirmed_transaction_id
      assert_equal "confirmed", transaction.reload.status
      assert_nil @household.household_operation_executions.find_by(idempotency_key: "broken-reopen")
      assert_nil @household.household_audit_events.find_by("metadata ->> 'idempotency_key' = ?", "broken-reopen")
    end
  end

  test "bulk confirm is atomic audited and replay safe" do
    travel_to Date.new(2026, 10, 1) do
      first = create_draft("bulk-confirm-first")
      second = create_draft("bulk-confirm-second", merchant: "Second Confirm")
      input = {
        draft_ids: [ first.id, second.id ], source_type: "manual_ui", year: 2026,
        confirmation: "CONFIRM 2"
      }

      assert_difference("HouseholdTransaction.count", 2) do
        @runner.run(operation_key: "transaction.drafts.bulk_confirm", input: input, idempotency_key: "bulk-confirm")
        replay = @runner.run(operation_key: "transaction.drafts.bulk_confirm", input: input, idempotency_key: "bulk-confirm")
        assert replay.replayed?
      end
      assert_equal %w[confirmed confirmed], [ first.reload.status, second.reload.status ]
      execution = @household.household_operation_executions.find_by!(idempotency_key: "bulk-confirm")
      assert_equal "transaction.drafts.bulk_confirm", execution.operation_key
      assert_equal [ first.id, second.id ].sort, execution.normalized_input.fetch("draft_ids")
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

  test "reordering unchanged split objects preserves the stable draft category and provenance" do
    travel_to Date.new(2026, 10, 1) do
      dining = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 200)
      draft = @household.transaction_drafts.create!(
        occurred_on: Date.new(2026, 9, 28), merchant: "Reordered Receipt", total_amount_cents: 5_000,
        budget_category: @category, source_type: "receipt", status: "pending"
      )
      primary = draft.transaction_draft_splits.create!(budget_category: @category, amount_cents: 3_000, confidence: 0.78, metadata: { "line" => 1 })
      secondary = draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 2_000, confidence: 0.66, metadata: { "line" => 2 })

      reordered = @runner.run(
        operation_key: "transaction.draft.update",
        input: {
          draft_id: draft.id, source_type: "manual_ui", removed_split_ids: [],
          splits: [
            { id: secondary.id, amount: "20", budget_category_id: dining.id },
            { id: primary.id, amount: "30", budget_category_id: @category.id }
          ]
        },
        idempotency_key: "multi-reorder"
      )

      assert_equal @category.id, draft.reload.budget_category_id
      assert_equal @category.id, reordered.execution.predicted_after_snapshot.dig("draft", "budget_category_id")
      assert_equal @category.id, reordered.execution.after_snapshot.dig("draft", "budget_category_id")
      assert_equal [ primary.id, secondary.id ], draft.transaction_draft_splits.order(:id).pluck(:id)
      assert_equal [ { "line" => 1 }, { "line" => 2 } ], draft.transaction_draft_splits.order(:id).map(&:metadata)
      assert_equal [ BigDecimal("0.78"), BigDecimal("0.66") ], draft.transaction_draft_splits.order(:id).map(&:confidence)
    end
  end

  test "manual split replacement explicitly retains removes and creates lines while Mia fails closed" do
    travel_to Date.new(2026, 10, 1) do
      dining = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 200)
      draft = @household.transaction_drafts.create!(
        occurred_on: Date.new(2026, 9, 28), merchant: "Editable Receipt", total_amount_cents: 5_000,
        budget_category: @category, source_type: "receipt", status: "pending"
      )
      retained = draft.transaction_draft_splits.create!(budget_category: @category, amount_cents: 3_000, confidence: 0.88, metadata: { "line" => 1 })
      removed = draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 2_000, confidence: 0.77, metadata: { "line" => 2 })
      input = {
        draft_id: draft.id, source_type: "manual_ui", removed_split_ids: [ removed.id ],
        splits: [
          { id: retained.id, amount: "30", budget_category_id: @category.id },
          { amount: "20", budget_category_id: dining.id, notes: "Manual replacement" }
        ]
      }

      ambiguous = assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: input.except(:removed_split_ids),
          idempotency_key: "manual-ambiguous-split-replacement"
        )
      end
      assert_includes ambiguous.message, "retained or removed"

      result = @runner.run(operation_key: "transaction.draft.update", input: input, idempotency_key: "manual-split-replacement")

      persisted = result.subject.transaction_draft_splits.order(:id).to_a
      assert_equal 2, persisted.length
      assert_equal retained.id, persisted.first.id
      assert_equal BigDecimal("0.88"), persisted.first.confidence
      assert_equal({ "line" => 1 }, persisted.first.metadata)
      assert_nil persisted.second.confidence
      assert_equal({ "human_reviewed_replacement" => true }, persisted.second.metadata)
      assert_equal @category.id, draft.reload.budget_category_id
      refute TransactionDraftSplit.exists?(removed.id)

      mia_error = assert_raises(ArgumentError) do
        @runner.run(
          operation_key: "transaction.draft.update",
          input: input.merge(source_type: "manual_chat"),
          idempotency_key: "mia-split-replacement",
          source: "mia"
        )
      end
      assert_includes mia_error.message, "cannot add or remove"
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
