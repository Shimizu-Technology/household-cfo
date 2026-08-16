require "test_helper"

class PlaidIntegrationAutoConfirmerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "auto_confirm_#{SecureRandom.hex(6)}", email: "auto-confirm@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @category = manager.create_category!(name: "Subscriptions", stack_key: "non_discretionary", monthly_amount: 100)
    @period = manager.current_period_for(Date.new(2026, 8, 1))
    @item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "auto-item", access_token: "auto-secret", institution_name: "Sandbox Bank", environment: "sandbox", consented_at: Time.current, consent_policy_version: "test", auto_confirm_trusted_merchants: true)
    @account = @item.plaid_accounts.create!(plaid_account_id: "auto-account", name: "Checking", account_type: "depository")
  end

  test "auto confirms only a familiar amount backed by a proven exact merchant rule" do
    3.times do |index|
      transaction = @household.household_transactions.create!(budget_period: @period, occurred_on: Date.new(2026, 8, index + 1), merchant: "Netflix", total_amount_cents: 1_957, source_type: "plaid", status: "confirmed")
      transaction.transaction_splits.create!(budget_category: @category, amount_cents: 1_957)
    end
    rule = @household.merchant_category_rules.create!(budget_category: @category, merchant_pattern: "netflix", confidence: BigDecimal("0.89"), source: "user_confirmed", times_confirmed: 3, last_confirmed_at: Time.current, active: true)
    source = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "next-netflix", name: "Netflix", merchant_name: "Netflix", occurred_on: Date.new(2026, 8, 16), amount_cents: 1_957, pending: false, source_fingerprint: SecureRandom.hex(32))
    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ source.id ], actor_type: "system").call.drafts.sole

    assert_difference("HouseholdTransaction.count", 1) do
      confirmed = PlaidIntegration::AutoConfirmer.new(@item, drafts: [ draft ]).call
      assert_equal 1, confirmed.length
    end

    assert_equal "confirmed", draft.reload.status
    event = @household.household_audit_events.order(:id).last
    assert_equal "plaid_transaction.auto_confirmed", event.event_type
    assert_equal rule.id, event.metadata.fetch("merchant_rule_id")
  end

  test "leaves an unusual amount in review" do
    3.times do |index|
      transaction = @household.household_transactions.create!(budget_period: @period, occurred_on: Date.new(2026, 8, index + 1), merchant: "Netflix", total_amount_cents: 1_957, source_type: "plaid", status: "confirmed")
      transaction.transaction_splits.create!(budget_category: @category, amount_cents: 1_957)
    end
    @household.merchant_category_rules.create!(budget_category: @category, merchant_pattern: "netflix", confidence: BigDecimal("0.89"), source: "user_confirmed", times_confirmed: 3, last_confirmed_at: Time.current, active: true)
    source = @item.plaid_transactions.create!(plaid_account: @account, plaid_transaction_id: "unusual-netflix", name: "Netflix", merchant_name: "Netflix", occurred_on: Date.new(2026, 8, 16), amount_cents: 25_000, pending: false, source_fingerprint: SecureRandom.hex(32))
    draft = PlaidIntegration::TransactionStager.new(household: @household, user: @user, transaction_ids: [ source.id ], actor_type: "system").call.drafts.sole

    assert_no_difference("HouseholdTransaction.count") do
      assert_empty PlaidIntegration::AutoConfirmer.new(@item, drafts: [ draft ]).call
    end
    assert draft.reload.pending?
  end

  test "never auto confirms into an Uncategorized placeholder" do
    placeholder = @household.budget_categories.create!(name: "Uncategorized", stack_key: "discretionary", active: true, sort_order: 99)
    3.times do |index|
      transaction = @household.household_transactions.create!(budget_period: @period, occurred_on: Date.new(2026, 8, index + 1), merchant: "Mystery Shop", total_amount_cents: 1_000, source_type: "plaid", status: "confirmed")
      transaction.transaction_splits.create!(budget_category: placeholder, amount_cents: 1_000)
    end
    @household.merchant_category_rules.create!(budget_category: placeholder, merchant_pattern: "mysteryshop", confidence: BigDecimal("0.95"), source: "user_confirmed", times_confirmed: 3, last_confirmed_at: Time.current, active: true)
    draft = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 8, 16), merchant: "Mystery Shop", total_amount_cents: 1_000, budget_category: placeholder, source_type: "plaid", status: "pending", raw_input: "Bank row")
    draft.transaction_draft_splits.create!(budget_category: placeholder, amount_cents: 1_000, category_name: placeholder.name, stack_key: placeholder.stack_key)

    assert_no_difference("HouseholdTransaction.count") do
      assert_empty PlaidIntegration::AutoConfirmer.new(@item, drafts: [ draft ]).call
    end
    assert draft.reload.pending?
  end
end
