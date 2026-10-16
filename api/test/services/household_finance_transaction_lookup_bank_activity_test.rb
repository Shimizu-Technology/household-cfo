require "test_helper"

class HouseholdFinanceTransactionLookupBankActivityTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "bank_lookup_#{SecureRandom.hex(6)}", email: "bank-lookup@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Shopping", stack_key: "discretionary", monthly_amount: 300)
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "lookup-item", access_token: "lookup-secret", institution_name: "Sandbox Bank", environment: "sandbox", consented_at: Time.current, consent_policy_version: "test")
    @account = @item.plaid_accounts.create!(plaid_account_id: "lookup-account", name: "Checking", account_type: "depository")
  end

  test "merchant answers separate bank observed, confirmed, review, and bank pending activity" do
    confirmed_source = plaid_transaction("confirmed-amazon", 7_227)
    plaid_transaction("review-amazon", 1_000)
    plaid_transaction("pending-amazon", 500, pending: true)

    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ confirmed_source.id ]).call.drafts.sole
    result = HouseholdFinance::TransactionDraftConfirmer.new(draft, { budget_category_id: @category.id }).call
    assert result.success?

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "How much did I spend at Amazon this month?",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "2 posted Amazon transactions totaling $82.27"
    assert_includes answer, "1 confirmed Amazon transaction totaling $72.27"
    assert_includes answer, "1 posted Amazon transaction totaling $10 still needs household review"
    assert_includes answer, "1 bank-pending Amazon transaction totaling $5"
  end

  test "bank summary leaves transfers and card payments out of outflows and review counts" do
    plaid_transaction("purchase-shop", 1_000, merchant: "Island Market")
    plaid_transaction("card-payment", 207_850, merchant: "Card Payment", primary: "LOAN_PAYMENTS", detailed: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    plaid_transaction("venmo", 4_500, merchant: "Venmo", primary: "TRANSFER_OUT", detailed: "TRANSFER_OUT_OTHER_TRANSFER_OUT")

    answer = HouseholdFinance::TransactionLookupAnswerer.new(@household, "Summarize my synced bank activity this month", today: Date.new(2026, 8, 16)).call

    assert_includes answer, "2 posted outflows totaling $55"
    assert_includes answer, "1 posted movement totaling $2,078.50 (transfers, card or loan payments) is not counted as spending"
    assert_includes answer, "2 posted outflows totaling $55 still need household review"
    refute_includes answer, "$2,078.50 still need"

    merchant = HouseholdFinance::TransactionLookupAnswerer.new(@household, "How much did I spend at Card Payment this month?", today: Date.new(2026, 8, 16)).call
    refute_match(/2,078/, merchant.to_s)
  end

  test "across synced bank activity uses all available history" do
    plaid_transaction("august-amazon", 1_000)
    plaid_transaction("july-amazon", 2_000, occurred_on: Date.new(2026, 7, 24))

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "Across my synced bank activity, how many Amazon transactions are there and what do they total?",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "For all available bank history"
    assert_includes answer, "2 posted Amazon transactions totaling $30"
  end

  test "connected account summary reports the most recent posted outflow without treating the account as a merchant" do
    plaid_transaction("older-outflow", 1_000, occurred_on: Date.new(2026, 8, 12), merchant: "Corner Store")
    plaid_transaction("recent-outflow", 433, occurred_on: Date.new(2026, 8, 14), merchant: "Starbucks")

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "What bank-observed activity do you see from my connected account? Summarize the most recent posted outflow, and do not change any numbers.",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "synced bank activity shows 2 posted outflows totaling $14.33"
    assert_includes answer, "Most recent posted outflow: Starbucks for $4.33 on Aug 14, 2026"
    assert_includes answer, "still needs household review and is not included in confirmed budget actuals"
    assert_not_includes answer, "my connected account transactions"
  end

  test "multi-part bank summary includes the requested top merchants" do
    plaid_transaction("amazon-one", 5_000, merchant: "Amazon")
    plaid_transaction("amazon-two", 2_500, merchant: "Amazon")
    plaid_transaction("payless", 4_000, merchant: "Pay-Less")
    plaid_transaction("coffee", 500, merchant: "Coffee Slut")

    answer = HouseholdFinance::TransactionLookupAnswerer.new(
      @household,
      "How much bank-observed spending do I have in August 2026, how many transactions still need review, and what are the top merchants? Do not change anything.",
      today: Date.new(2026, 8, 16)
    ).call

    assert_includes answer, "4 posted outflows totaling $120"
    assert_includes answer, "4 posted outflows totaling $120 still need household review"
    assert_includes answer, "Top merchants by posted outflow: Amazon — $75 (2 transactions); Pay-Less — $40 (1 transaction); Coffee Slut — $5 (1 transaction)."
  end

  test "bank avoidance is not treated as a bank activity lookup" do
    plaid_transaction("avoid-amazon", 1_000)

    [
      "I haven't looked at my bank account in two weeks because I'm scared of what I'll see.",
      "I havent checked my bank balance, what if it's bad?",
      "I've been avoiding my bank statements.",
      "I'm afraid to open my account. What will I find?"
    ].each do |prompt|
      assert HouseholdFinance::TransactionLookupAnswerer.avoidance?(prompt), prompt
      refute HouseholdFinance::TransactionLookupAnswerer.bank_activity_question?(prompt), prompt
      assert_nil HouseholdFinance::TransactionLookupAnswerer.new(@household, prompt, today: Date.new(2026, 8, 16)).call, prompt
    end
  end

  test "real bank activity questions still return the lookup, even when stress is mentioned" do
    plaid_transaction("week-amazon", 1_000)

    [
      "What did I spend at Amazon last week?",
      "I'm anxious about my bank account. How much did I spend at Amazon this month?"
    ].each do |prompt|
      refute HouseholdFinance::TransactionLookupAnswerer.avoidance?(prompt), prompt
      answer = HouseholdFinance::TransactionLookupAnswerer.new(@household, prompt, today: Date.new(2026, 8, 16)).call
      assert_includes answer, "Amazon", prompt
    end
    assert HouseholdFinance::TransactionLookupAnswerer.bank_activity_question?("I'm anxious about my bank account. How much did I spend at Amazon this month?")
  end

  test "fear about a specific account problem is not avoidance" do
    [
      "I'm anxious because my balance is only $40 and rent is due Friday",
      "I'm scared someone hacked my bank account",
      "I'm afraid my account will overdraft when rent comes out",
      "I'm afraid to put my savings account money into crypto, should I?",
      "I'm scared to look, what's my checking account balance?",
      "I didn't look at my account this week, can you tell me what I spent?",
      "Dont want to look at my statement, whats my balance",
      "I'm scared to see what I owe on my credit card",
      "I dont check my account because my husband handles it",
      "I avoid the bank because the fees scare me"
    ].each do |prompt|
      refute HouseholdFinance::TransactionLookupAnswerer.avoidance?(prompt), prompt
    end
  end

  private

  def plaid_transaction(id, amount_cents, pending: false, occurred_on: Date.new(2026, 8, 14), merchant: "Amazon", primary: "GENERAL_MERCHANDISE", detailed: nil)
    @item.plaid_transactions.create!(
      plaid_account: @account,
      plaid_transaction_id: id,
      name: merchant,
      merchant_name: merchant,
      occurred_on: occurred_on,
      amount_cents: amount_cents,
      pending: pending,
      primary_category: primary,
      detailed_category: detailed,
      source_fingerprint: SecureRandom.hex(32)
    )
  end
end
