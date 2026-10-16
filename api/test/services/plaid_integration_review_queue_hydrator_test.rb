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
    legacy.update!(transaction_draft: legacy_draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)

    staged = PlaidIntegration::ReviewQueueHydrator.new(@item).call

    assert_equal [ purchase.reload.transaction_draft ], staged
    assert_equal "unreviewed", transfer.reload.review_status
    assert_nil transfer.transaction_draft_id
    assert_equal "unreviewed", legacy.reload.review_status
    assert_nil legacy.transaction_draft_id
    refute TransactionDraft.exists?(legacy_draft.id)
    assert_equal "plaid_transaction.not_counted_as_spending", @household.household_audit_events.where(event_type: "plaid_transaction.not_counted_as_spending").sole.event_type
  end

  test "leaves a decided card-payment draft untouched" do
    legacy = create_transaction("hydrator-confirmed-card", "CREDIT CARD 3333 PAYMENT", 2_500, "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT")
    draft = @household.transaction_drafts.create!(occurred_on: legacy.occurred_on, merchant: legacy.name, total_amount_cents: legacy.amount_cents, source_type: "plaid", status: "ignored")
    legacy.update!(transaction_draft: draft, review_status: "drafted", drafted_source_fingerprint: legacy.source_fingerprint)

    PlaidIntegration::ReviewQueueHydrator.new(@item).call

    assert_equal draft, legacy.reload.transaction_draft
    assert_equal "drafted", legacy.review_status
  end

  private

  def create_transaction(id, name, amount_cents, primary, detailed)
    @item.plaid_transactions.create!(
      plaid_account: @account, plaid_transaction_id: id, name: name, occurred_on: Date.new(2026, 8, 1), amount_cents: amount_cents,
      pending: false, primary_category: primary, detailed_category: detailed, source_fingerprint: SecureRandom.hex(32)
    )
  end
end
