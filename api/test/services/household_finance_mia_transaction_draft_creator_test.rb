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

  test "savings deposits and investment buys never become expense reviews" do
    [
      "Paid $50 to Bank of Guam savings for the challenge",
      "Put $40 in my savings",
      "Transferred $100 to my challenge account",
      "Moved $25 into savings",
      "I paid $60 to my savings today",
      "Bought $200 worth of bitcoin",
      "I spent $100 on crypto",
      "Put $300 into stocks",
      "I bought $150 of bitcoin from Coinbase"
    ].each_with_index do |message, index|
      assert_no_difference("TransactionDraft.count", message) do
        assert_nil HouseholdFinance::TransactionDraftBuilder.new(@household, message, user: @user, idempotency_key: "movement-#{index}").call, message
        result = HouseholdFinance::MiaTransactionDraftCreator.new(
          @household,
          user: @user,
          command: { merchant: "Bank", amount: "50", occurred_on: "2026-07-10", splits: [] },
          raw_input: message,
          idempotency_key: "movement-model-#{index}"
        ).call
        refute result.success?, message
      end
    end
  end

  test "a spend beside a deposit drafts only the spend, and stock buys draft nothing" do
    {
      "I spent $30 on groceries and put $50 in savings" => 3_000,
      "I spent $30 on groceries today and put $50 in savings" => 3_000,
      "Put $50 in savings and spent $30 at Payless" => 3_000,
      "I paid $20 for gas then moved $100 into savings" => 2_000,
      "I put $50 in savings and spent $30 on groceries" => 3_000,
      "I paid $50 to my savings and $30 for gas" => 3_000,
      "I paid $30 for gas and $50 to my savings" => 3_000,
      "I paid $100 to savings, $30 to Payless" => 3_000,
      "I paid $30 to Payless, $100 to savings" => 3_000,
      "I paid $50 to savings and then $30 for gas" => 3_000,
      "I paid $50 to savings and also $30 for gas" => 3_000,
      "I paid $50 to savings, then $30 for gas" => 3_000,
      "I paid $30 for gas and then $50 to my savings" => 3_000,
      "I put $50 in savings and then spent $30 on groceries" => 3_000
    }.each_with_index do |(message, cents), index|
      draft = HouseholdFinance::TransactionDraftBuilder.new(@household, message, user: @user, idempotency_key: "mixed-deposit-#{index}").call
      assert draft, message
      assert_equal cents, draft.total_amount_cents, message
      refute_match(/savings/i, draft.merchant, message)
    end

    assert_no_difference("TransactionDraft.count") do
      [ "I bought $50 of Apple stock", "Bought groceries for $30 and put $50 in savings",
        "I put $40 in savings and paid my $50 visa bill", "I paid my $50 visa bill and put $40 in savings" ].each_with_index do |message, index|
        assert_nil HouseholdFinance::TransactionDraftBuilder.new(@household, message, user: @user, idempotency_key: "stock-#{index}").call, message
      end
    end

    model = ->(message, amount, key) do
      HouseholdFinance::MiaTransactionDraftCreator.new(@household, user: @user, idempotency_key: key, raw_input: message,
        command: { merchant: "Payless", amount: amount, occurred_on: "2026-07-10", splits: [] }).call
    end
    assert model.call("I spent $30 on groceries and put $50 in savings", "30", "model-mixed-30").success?
    refute model.call("I spent $30 on groceries and put $50 in savings", "50", "model-mixed-50").success?
  end

  test "real spends that mention savings or sit beside a deposit still become reviews" do
    {
      "I spent $50 at the Savings Mart" => [ 5_000, "the Savings Mart" ],
      "Spent $40 at Kmart and put $20 in savings" => [ 4_000, "Kmart" ],
      "I bought $15 of snacks at the Savings Mart" => [ 1_500, "the Savings Mart" ],
      "I spent $50 at Payless and moved $25 into savings." => [ 5_000, "Payless" ]
    }.each_with_index do |(message, (cents, merchant)), index|
      draft = HouseholdFinance::TransactionDraftBuilder.new(@household, message, user: @user, idempotency_key: "real-spend-#{index}").call
      assert draft, message
      assert_equal cents, draft.total_amount_cents, message
      assert_equal merchant, draft.merchant, message
    end
  end

  test "shorthand thousands draft the full amount, and k must stand alone" do
    {
      "I spent $5k at Home Depot" => 500_000,
      "I spent $2K at Costco" => 200_000,
      "Spent $1.5k at Triple J Motors" => 150_000,
      "I spent $3 thousand at Triple J Motors" => 300_000,
      "I spent 2k at Costco" => 200_000,
      "I spent $5 at Kmart" => 500,
      "Bought $5 kids meal at Jollibee" => 500
    }.each_with_index do |(message, cents), index|
      draft = HouseholdFinance::TransactionDraftBuilder.new(@household, message, user: @user, idempotency_key: "shorthand-#{index}").call
      assert draft, message
      assert_equal cents, draft.total_amount_cents, message
    end
    assert_equal({ amount: "2000", merchant: "Costco" }, HouseholdFinance::TransactionDraftBuilder.explicit_purchase_details("I spent $2k at Costco"))
  end
end
