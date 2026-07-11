require "test_helper"

class HouseholdFinanceMiaTransactionDraftIgnorerTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "mia-draft-ignore@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household).create_category!(name: "Flexible spending", stack_key: "discretionary", monthly_amount: 500)
  end

  test "explicit all request ignores every pending review without changing actuals" do
    drafts = [ create_draft("Ignore One", 1_100), create_draft("Ignore Two", 2_200) ]

    assert_no_difference("HouseholdTransaction.count") do
      result = HouseholdFinance::MiaTransactionDraftIgnorer.new(
        @household,
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
      command: { type: "ignore_transaction_drafts", merchant: "Repeated Merchant", all_pending: false },
      raw_input: "Ignore the Repeated Merchant review"
    ).call
    non_explicit = HouseholdFinance::MiaTransactionDraftIgnorer.new(
      @household,
      command: { type: "ignore_transaction_drafts", all_pending: true },
      raw_input: "What is pending?"
    ).call

    refute ambiguous.success?
    assert_includes ambiguous.response, "I found 2 matching"
    refute non_explicit.success?
    assert_equal %w[pending pending], [ first.reload.status, second.reload.status ]
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
