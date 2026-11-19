require "test_helper"

# A purchase that looks like one she already has must never count twice
# without her saying so. The Talun names below are fictional.
class HouseholdFinanceTransactionDraftPossibleDuplicateTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(clerk_id: "possible_duplicate_#{SecureRandom.hex(8)}", email: "possible-duplicate-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @groceries = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 600)
    @household_goods = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Household", stack_key: "discretionary", monthly_amount: 200)
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "confirming a purchase with a proposed match changes nothing and asks" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = existing_purchase(merchant: "Payless Supermarket", cents: 10_342, on: Date.new(2026, 8, 3))
      draft = create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")
      match = draft.transaction_draft_matches.sole
      assert_equal "proposed", match.status

      result = HouseholdFinance::TransactionDraftConfirmer.new(draft).call

      refute result.success?
      assert_equal [ "This looks like Payless Supermarket on Aug 3 ($103.42), which you already have. Is it the same purchase or a different one? Nothing changed." ], result.errors
      assert_equal [ bank_line.id ], result.possible_matches.map { |candidate| candidate.fetch(:transaction_id) }
      assert_equal "pending", draft.reload.status
      assert_equal "proposed", match.reload.status
      assert_equal [ bank_line.id ], @household.household_transactions.pluck(:id)
    end
  end

  test "different purchase confirms deliberately and keeps her answer" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = existing_purchase(merchant: "Payless Supermarket", cents: 10_342, on: Date.new(2026, 8, 3))
      draft = create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")
      match = draft.transaction_draft_matches.sole

      result = HouseholdFinance::TransactionDraftConfirmer.new(draft, different_purchase: true).call

      assert result.success?, result.errors.to_sentence
      assert_equal "confirmed", draft.reload.status
      assert_equal "rejected", match.reload.status, "the rejected suggestion is kept, not destroyed"
      assert_equal 2, @household.household_transactions.where(status: "confirmed").count

      # Reopened later, the same suggestion is not asked again.
      reopened = HouseholdFinance::TransactionDraftReopener.new(draft).call
      assert reopened.success?, reopened.errors.to_sentence
      assert_equal "rejected", match.reload.status
      assert_empty draft.reload.transaction_draft_matches.proposed
      again = HouseholdFinance::TransactionDraftConfirmer.new(draft).call
      assert again.success?, again.errors.to_sentence
      assert_equal [ bank_line.id, again.transaction.id ].sort, @household.household_transactions.where(status: "confirmed").pluck(:id).sort
    end
  end

  test "a voucher receipt corrected to its new money is compared with the bank line before it counts" do
    travel_to Date.new(2026, 7, 1) do
      bank_line = existing_purchase(merchant: "Purchase authorized on 06/23 Tasi Demo Home Store Tamuning Gum", cents: 3_488, on: Date.new(2026, 6, 23), category: @household_goods)
      receipt = create_draft(merchant: "Tasi Demo Home Store", amount: "184.88", on: "2026-06-23", category: @household_goods)
      assert_empty receipt.transaction_draft_matches, "the receipt's total does not look like the $34.88 bank line"

      result = HouseholdFinance::TransactionDraftConfirmer.new(receipt, { amount: "34.88", budget_category_id: @household_goods.id }).call

      refute result.success?
      assert_equal [ bank_line.id ], result.possible_matches.map { |candidate| candidate.fetch(:transaction_id) }
      assert_match "Tasi Demo Home Store on Jun 23 ($34.88)", result.errors.sole
      receipt.reload
      assert_equal "pending", receipt.status
      assert_equal 18_488, receipt.total_amount_cents, "the refused correction is not half-saved"
      assert_empty receipt.transaction_draft_matches
      assert_equal 1, @household.household_transactions.count

      # "Same purchase": the edit is saved, the card shows the match, and she accepts it.
      split = receipt.transaction_draft_splits.sole
      saved = HouseholdFinance::TransactionDraftUpdater.new(receipt, { amount: "34.88", splits: [ { id: split.id, amount: "34.88", budget_category_id: @household_goods.id } ] }).call
      assert saved.success?, saved.errors.to_sentence
      match = receipt.reload.transaction_draft_matches.proposed.sole
      accepted = HouseholdFinance::TransactionDraftMatchAccepter.new(receipt, match_id: match.id).call

      assert accepted.success?, accepted.errors.to_sentence
      assert_equal "matched", receipt.reload.status
      assert_equal bank_line.id, receipt.matched_transaction_id
      assert_equal [ bank_line.id ], @household.household_transactions.pluck(:id), "matching never adds a second purchase"
    end
  end

  test "a refusal inside a caller's transaction leaves the correction unsaved" do
    travel_to Date.new(2026, 7, 1) do
      existing_purchase(merchant: "Tasi Demo Home Store", cents: 3_488, on: Date.new(2026, 6, 23), category: @household_goods)
      receipt = create_draft(merchant: "Tasi Demo Home Store", amount: "184.88", on: "2026-06-23", category: @household_goods)

      ApplicationRecord.transaction do
        result = HouseholdFinance::TransactionDraftConfirmer.new(receipt, { amount: "34.88" }).call
        refute result.success?
        assert_equal 18_488, receipt.reload.total_amount_cents
        assert_equal [ 18_488 ], receipt.transaction_draft_splits.pluck(:amount_cents)
        assert_empty receipt.transaction_draft_matches
      end
    end
  end

  test "a bank line approved after the purchase was logged is still caught" do
    travel_to Date.new(2026, 8, 10) do
      draft = create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")
      assert_empty draft.transaction_draft_matches
      bank_line = existing_purchase(merchant: "POS PURCHASE PAYLESS SUPERMARKET TAMUNING GU", cents: 10_342, on: Date.new(2026, 8, 4))

      result = HouseholdFinance::TransactionDraftConfirmer.new(draft).call

      refute result.success?
      assert_equal [ bank_line.id ], result.possible_matches.map { |candidate| candidate.fetch(:transaction_id) }
      assert_equal "pending", draft.reload.status
    end
  end

  test "the operation refuses with the matches and confirms only with her answer" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = existing_purchase(merchant: "Payless Supermarket", cents: 10_342, on: Date.new(2026, 8, 3))
      draft = create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")

      error = assert_raises(HouseholdFinance::TransactionDraftConfirmer::PossibleDuplicate) do
        @runner.run(operation_key: "transaction.draft.confirm", input: { draft_id: draft.id, source_type: "manual_ui" }, idempotency_key: "confirm-asks")
      end
      assert_equal [ bank_line.id ], error.matches.map { |candidate| candidate.fetch(:transaction_id) }
      assert_equal 0, @household.household_operation_executions.where(operation_key: "transaction.draft.confirm").count

      input = { draft_id: draft.id, source_type: "manual_ui", different_purchase: true }
      first = @runner.run(operation_key: "transaction.draft.confirm", input: input, idempotency_key: "confirm-different")
      replay = @runner.run(operation_key: "transaction.draft.confirm", input: input, idempotency_key: "confirm-different")

      assert replay.replayed?
      assert_equal true, first.execution.normalized_input.fetch("different_purchase")
      assert_equal "confirmed", draft.reload.status
      assert_equal 2, @household.household_transactions.count
    end
  end

  test "bulk confirm never answers the question for her" do
    travel_to Date.new(2026, 8, 10) do
      existing_purchase(merchant: "Payless Supermarket", cents: 10_342, on: Date.new(2026, 8, 3))
      plain = create_draft(merchant: "Talun Fruit Stand", amount: "12.00", on: "2026-08-05")
      asking = create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")

      result = HouseholdFinance::TransactionDraftBulkResolver.new(@household, draft_ids: [ plain.id, asking.id ], action: "confirm").call

      refute result.success?
      assert_equal [ "Payless Supermarket for $103.42 may be a purchase you already have. Answer “Same purchase?” on that purchase first. Nothing changed." ], result.errors
      assert_equal %w[pending pending], [ plain.reload.status, asking.reload.status ]
      assert_equal 1, @household.household_transactions.count
    end
  end

  test "matcher compares cleaned store names so a bank descriptor one day off is offered" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = existing_purchase(merchant: "Purchase authorized on 08/02 Tasi Demo Home Store Tamuning Gum S*0000 Card 7302", cents: 3_488, on: Date.new(2026, 8, 2))
      receipt = create_draft(merchant: "TASI DEMO HOME STORE #12", amount: "34.88", on: "2026-08-03", category: nil)

      matches = receipt.transaction_draft_matches.proposed.to_a
      assert_equal [ bank_line.id ], matches.map(&:household_transaction_id)
      assert_operator matches.sole.confidence, :>=, HouseholdFinance::TransactionDraftMatcher::MIN_CONFIDENCE
    end
  end

  test "matcher still ignores a different store for the same amount a day apart" do
    travel_to Date.new(2026, 8, 10) do
      existing_purchase(merchant: "Purchase authorized on 08/02 Hafa Demo Pharmacy Dededo GU", cents: 3_488, on: Date.new(2026, 8, 2))
      receipt = create_draft(merchant: "TASI DEMO HOME STORE #12", amount: "34.88", on: "2026-08-03", category: nil)

      assert_empty receipt.transaction_draft_matches
    end
  end

  test "a purchase already matched to another entry she typed is not offered again" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = existing_purchase(merchant: "Payless Supermarkets - Mangilao", cents: 10_342, on: Date.new(2026, 8, 3))
      first = create_draft(merchant: "Payless", amount: "103.42", on: "2026-08-03")
      second = create_draft(merchant: "Payless", amount: "103.42", on: "2026-08-03")
      assert_equal [ bank_line.id ], second.transaction_draft_matches.proposed.map(&:household_transaction_id)

      matched = HouseholdFinance::TransactionDraftMatchAccepter.new(first, match_id: first.transaction_draft_matches.proposed.sole.id).call
      assert matched.success?, matched.errors.to_sentence

      HouseholdFinance::TransactionDraftMatcher.new(second.reload).call
      assert_empty second.reload.transaction_draft_matches.proposed, "the taken bank line is no longer suggested"
      result = HouseholdFinance::TransactionDraftConfirmer.new(second).call
      assert result.success?, result.errors.to_sentence
    end
  end

  private

  def existing_purchase(merchant:, cents:, on:, category: @groceries)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: on.year).current_period_for(on)
    @household.household_transactions.create!(budget_period: period, occurred_on: on, merchant: merchant,
      total_amount_cents: cents, source_type: "statement", status: "confirmed").tap do |transaction|
      transaction.transaction_splits.create!(budget_category: category, amount_cents: cents)
    end
  end

  def create_draft(merchant:, amount:, on:, category: @groceries)
    input = { occurred_on: on, merchant: merchant, amount: amount, source_type: "manual_ui" }
    input[:budget_category_id] = category.id if category
    @runner.run(operation_key: "transaction.draft.create", input: input, idempotency_key: SecureRandom.uuid).subject.reload
  end
end
