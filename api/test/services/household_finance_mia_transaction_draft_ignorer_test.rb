require "test_helper"

class HouseholdFinanceMiaTransactionDraftIgnorerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "mia-draft-ignore@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household).create_category!(name: "Flexible spending", stack_key: "discretionary", monthly_amount: 500)
  end

  test "explicit all request ignores every pending review without changing actuals" do
    drafts = [ create_draft("Ignore One", 1_100), create_draft("Ignore Two", 2_200) ]

    assert_no_difference("HouseholdTransaction.count") do
      result = HouseholdFinance::MiaTransactionDraftIgnorer.new(
        @household,
        user: @user,
        command: { type: "ignore_transaction_drafts", all_pending: true },
        raw_input: "Clear all of them and ignore every pending review"
      ).call

      assert result.success?
      assert_equal 2, result.drafts.length
      assert_includes result.response, "Ignored 2 pending transaction reviews"
      assert_includes result.response, "Actuals did not change"
    end
    assert_equal %w[ignored ignored], drafts.map { |draft| draft.reload.status }
  end

  test "specific merchant request ignores one uniquely matching pending review" do
    target = create_draft("Disney Plus", 1_899)
    create_draft("Other Merchant", 2_000)

    result = HouseholdFinance::MiaTransactionDraftIgnorer.new(
      @household,
      user: @user,
      command: { type: "ignore_transaction_drafts", merchant: "Disney Plus", all_pending: false },
      raw_input: "Clear the pending Disney Plus review"
    ).call

    assert result.success?
    assert_equal [ target.id ], result.drafts.map(&:id)
    assert_equal "ignored", target.reload.status
  end

  test "ambiguous and non-explicit requests change nothing" do
    first = create_draft("Repeated Merchant", 1_100)
    second = create_draft("Repeated Merchant", 2_200)

    ambiguous = HouseholdFinance::MiaTransactionDraftIgnorer.new(
      @household,
      user: @user,
      command: { type: "ignore_transaction_drafts", merchant: "Repeated Merchant", all_pending: false },
      raw_input: "Ignore the Repeated Merchant review"
    ).call
    non_explicit = HouseholdFinance::MiaTransactionDraftIgnorer.new(
      @household,
      user: @user,
      command: { type: "ignore_transaction_drafts", all_pending: true },
      raw_input: "What is pending?"
    ).call

    refute ambiguous.success?
    assert_includes ambiguous.response, "I found 2 matching"
    refute non_explicit.success?
    assert_equal %w[pending pending], [ first.reload.status, second.reload.status ]
  end

  test "ignore all reports the five hundred review boundary without mutating a larger queue" do
    timestamp = Time.current
    TransactionDraft.insert_all!(
      501.times.map do |index|
        {
          household_id: @household.id,
          occurred_on: Date.current,
          merchant: "Bounded queue #{index}",
          total_amount_cents: 100,
          source_type: "manual_chat",
          status: "pending",
          raw_input: "Bounded queue",
          created_at: timestamp + index.seconds,
          updated_at: timestamp + index.seconds
        }
      end
    )

    result = HouseholdFinance::MiaTransactionDraftIgnorer.new(
      @household,
      user: @user,
      command: { type: "ignore_transaction_drafts", all_pending: true },
      raw_input: "Ignore all pending reviews"
    ).call

    refute result.success?
    assert_includes result.response, "safely ignore at most 500"
    assert_includes result.response, "nothing changed"
    assert_equal 501, @household.transaction_drafts.pending.count
  end

  test "operation failures return a safe failure result without changing the draft" do
    draft = create_draft("Runner Failure", 1_100)
    invalid_record = TransactionDraft.new
    invalid_record.errors.add(:base, "Concurrent review conflict")
    errors = [ ArgumentError.new("Review changed"), ActiveRecord::RecordInvalid.new(invalid_record) ]

    errors.each_with_index do |error, index|
      runner = Object.new
      runner.define_singleton_method(:run) { |**| raise error }
      runner_class = HouseholdFinance::Operations::Runner.singleton_class
      original_new = runner_class.instance_method(:new)
      runner_class.define_method(:new) { |*, **| runner }
      result = begin
        HouseholdFinance::MiaTransactionDraftIgnorer.new(
          @household,
          user: @user,
          command: { type: "ignore_transaction_drafts", draft_id: draft.id, all_pending: false },
          raw_input: "Ignore the Runner Failure review",
          idempotency_key: "runner-failure-#{index}"
        ).call
      ensure
        runner_class.define_method(:new, original_new)
      end

      refute result.success?
      assert_includes result.response, "Nothing changed"
      assert_equal "pending", draft.reload.status
    end
  end

  private

  def create_draft(merchant, amount_cents)
    draft = @household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: merchant,
      total_amount_cents: amount_cents,
      budget_category: @category,
      source_type: "manual_chat",
      status: "pending",
      raw_input: merchant
    )
    draft.transaction_draft_splits.create!(budget_category: @category, category_name: @category.name, stack_key: @category.stack_key, amount_cents: amount_cents)
    draft
  end
end
