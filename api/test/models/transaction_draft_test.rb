require "test_helper"

class TransactionDraftTest < ActiveSupport::TestCase
  test "recent first follows the transaction date before creation order" do
    user = User.create!(clerk_id: "draft_order_#{SecureRandom.hex(6)}", email: "draft-order@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    older = household.transaction_drafts.create!(occurred_on: Date.new(2026, 1, 10), merchant: "Older purchase", total_amount_cents: 1_000, source_type: "plaid", status: "pending")
    newer = household.transaction_drafts.create!(occurred_on: Date.new(2026, 8, 10), merchant: "Newer purchase", total_amount_cents: 2_000, source_type: "plaid", status: "pending")

    older.update_column(:created_at, 1.hour.from_now)

    assert_equal [ newer.id, older.id ], household.transaction_drafts.recent_first.pluck(:id)
  end
end
