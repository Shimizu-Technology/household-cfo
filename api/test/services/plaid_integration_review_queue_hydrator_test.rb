require "test_helper"

class PlaidIntegrationReviewQueueHydratorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "hydrator_#{SecureRandom.hex(6)}", email: "plaid-hydrator@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @item = @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "hydrator-item",
      access_token: "hydrator-secret",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test"
    )
    @account = @item.plaid_accounts.create!(plaid_account_id: "hydrator-account", name: "Checking", account_type: "depository")
  end

  test "reports a failed staging batch and continues hydrating later batches" do
    now = Time.current
    PlaidTransaction.insert_all!(
      101.times.map do |index|
        {
          plaid_item_id: @item.id,
          plaid_account_id: @account.id,
          plaid_transaction_id: "hydrator-transaction-#{index}",
          name: "Merchant #{index}",
          occurred_on: Date.new(2026, 8, 1),
          amount_cents: 1_000 + index,
          pending: false,
          review_status: "unreviewed",
          source_fingerprint: SecureRandom.hex(32),
          created_at: now,
          updated_at: now
        }
      end
    )

    calls = 0
    staged_draft = Object.new
    stager_factory = lambda do |**_attributes|
      calls += 1
      if calls == 1
        Object.new.tap do |stager|
          stager.define_singleton_method(:call) { raise PlaidIntegration::Error, "one batch failed" }
        end
      else
        Object.new.tap do |stager|
          stager.define_singleton_method(:call) do
            PlaidIntegration::TransactionStager::Result.new(drafts: [ staged_draft ], errors: [])
          end
        end
      end
    end
    singleton = class << PlaidIntegration::TransactionStager; self; end
    original = PlaidIntegration::TransactionStager.method(:new)
    singleton.define_method(:new) { |**attributes| stager_factory.call(**attributes) }
    begin
      staged = PlaidIntegration::ReviewQueueHydrator.new(@item).call
    ensure
      singleton.define_method(:new, original)
    end

    assert_equal 2, calls
    assert_equal [ staged_draft ], staged
  end

  test "keeps staged drafts when optional auto-confirmation fails" do
    @item.update!(auto_confirm_trusted_merchants: true)
    transaction = @item.plaid_transactions.create!(
      plaid_account: @account,
      plaid_transaction_id: "auto-confirm-failure",
      name: "Merchant",
      occurred_on: Date.new(2026, 8, 1),
      amount_cents: 1_000,
      pending: false,
      source_fingerprint: SecureRandom.hex(32)
    )
    failing_auto_confirmer = Object.new
    failing_auto_confirmer.define_singleton_method(:call) { raise ActiveRecord::RecordInvalid }
    singleton = class << PlaidIntegration::AutoConfirmer; self; end
    original = PlaidIntegration::AutoConfirmer.method(:new)
    singleton.define_method(:new) { |*_arguments, **_options| failing_auto_confirmer }
    begin
      staged = PlaidIntegration::ReviewQueueHydrator.new(@item).call
    ensure
      singleton.define_method(:new, original)
    end

    assert_equal [ transaction.reload.transaction_draft ], staged
    assert_equal "drafted", transaction.review_status
  end

  test "queues purchases only and returns earlier card-payment drafts to bank activity" do
    purchase = create_transaction("hydrator-purchase", "Island Market", 4_200, "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES")
    transfer = create_transaction("hydrator-transfer", "CD DEPOSIT .INITIAL.", 100_000, "TRANSFER_OUT", "TRANSFER_OUT_ACCOUNT_TRANSFER")
    legacy = create_transaction("hydrator-card", "CREDIT CARD 3333 PAYMENT", 2_500, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    legacy_draft = @household.transaction_drafts.create!(occurred_on: legacy.occurred_on, merchant: legacy.name, total_amount_cents: legacy.amount_cents, source_type: "plaid", status: "pending")
    legacy_draft.transaction_draft_splits.create!(amount_cents: legacy.amount_cents)
    legacy.update!(transaction_draft: legacy_draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)

    staged = PlaidIntegration::ReviewQueueHydrator.new(@item).call

    assert_equal [ purchase.reload.transaction_draft ], staged
    assert_equal "unreviewed", transfer.reload.review_status
    assert_nil transfer.transaction_draft_id
    assert_equal "unreviewed", legacy.reload.review_status
    assert_nil legacy.transaction_draft_id
    refute TransactionDraft.exists?(legacy_draft.id)
    audit = @household.household_audit_events.where(event_type: "plaid_transaction.not_counted_as_spending").sole
    assert_equal legacy.name, audit.metadata.dig("prior_draft", "draft", "merchant")
    assert_equal 1, audit.metadata.dig("prior_draft", "splits").length
  end

  test "keeps a participant-edited legacy draft instead of destroying it" do
    legacy = create_transaction("hydrator-edited", "MORTGAGE PAYMENT", 150_000, "LOAN_PAYMENTS", "LOAN_PAYMENTS_MORTGAGE_PAYMENT")
    category = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Housing", stack_key: "discretionary", monthly_amount: 1500)
    draft = @household.transaction_drafts.create!(occurred_on: legacy.occurred_on, merchant: legacy.name, total_amount_cents: legacy.amount_cents, source_type: "plaid", status: "pending", budget_category: category)
    draft.transaction_draft_splits.create!(amount_cents: legacy.amount_cents, budget_category: category)
    legacy.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)

    PlaidIntegration::ReviewQueueHydrator.new(@item).call

    assert_equal draft, legacy.reload.transaction_draft
    assert TransactionDraft.exists?(draft.id)
    assert_empty @household.household_audit_events.where(event_type: "plaid_transaction.not_counted_as_spending")
  end

  test "keeps a legacy draft whose split carries a participant note" do
    legacy = create_transaction("hydrator-note", "CARD PAYMENT N", 1_000, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    draft = @household.transaction_drafts.create!(occurred_on: legacy.occurred_on, merchant: legacy.name, total_amount_cents: legacy.amount_cents, source_type: "plaid", status: "pending")
    draft.transaction_draft_splits.create!(amount_cents: legacy.amount_cents, notes: "my note")
    legacy.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)

    PlaidIntegration::ReviewQueueHydrator.new(@item).call

    assert TransactionDraft.exists?(draft.id)
  end

  test "one failing release does not block the others" do
    first = create_transaction("hydrator-fail-1", "CARD PAYMENT A", 1_000, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    second = create_transaction("hydrator-fail-2", "CARD PAYMENT B", 2_000, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    [ first, second ].each do |legacy|
      draft = @household.transaction_drafts.create!(occurred_on: legacy.occurred_on, merchant: legacy.name, total_amount_cents: legacy.amount_cents, source_type: "plaid", status: "pending")
      draft.transaction_draft_splits.create!(amount_cents: legacy.amount_cents)
      legacy.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)
    end
    reported = []
    failing = Module.new do
      define_method(:update!) { |*args, **kw| name == "CARD PAYMENT A" && review_status == "drafted" ? raise(ActiveRecord::RecordNotSaved, "boom") : super(*args, **kw) }
    end
    PlaidTransaction.prepend(failing)
    begin
      subscriber = Object.new
      subscriber.define_singleton_method(:report) { |error, **_opts| reported << error }
      Rails.error.subscribe(subscriber)
      PlaidIntegration::ReviewQueueHydrator.new(@item).call
    ensure
      Rails.error.unsubscribe(subscriber) if subscriber
      failing.send(:remove_method, :update!)
    end

    assert_equal 1, reported.length
    assert_equal "drafted", first.reload.review_status
    assert_equal "unreviewed", second.reload.review_status
  end

  private

  def create_transaction(id, name, amount_cents, primary, detailed)
    @item.plaid_transactions.create!(
      plaid_account: @account, plaid_transaction_id: id, name: name, occurred_on: Date.new(2026, 8, 1), amount_cents: amount_cents,
      pending: false, primary_category: primary, detailed_category: detailed, source_fingerprint: SecureRandom.hex(32)
    )
  end
end
