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
end
