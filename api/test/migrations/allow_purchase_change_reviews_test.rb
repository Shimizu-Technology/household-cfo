require "test_helper"
require Rails.root.join("db/migrate/20261112090000_allow_purchase_change_reviews").to_s

class AllowPurchaseChangeReviewsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "pc_migration_#{SecureRandom.hex(4)}", email: "pc-migration-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "rolling back with no purchase reviews restores the old constraints, and rolling forward allows them again" do
    AllowPurchaseChangeReviews.new.migrate(:down)
    assert_not accepts?("purchase_change", "change_purchase")
    assert accepts?("asset_plan", "update_account"), "the older review types still work"
    AllowPurchaseChangeReviews.new.migrate(:up)
    assert accepts?("purchase_change", "change_purchase")
  end

  test "rollback refuses while a purchase review exists and keeps its draft, item and application" do
    draft = create_draft("purchase_change")
    item = draft.mia_action_items.create!(action_type: "change_purchase", position: 0, label: "Change Target")
    application = draft.mia_action_draft_applications.create!(household: @household, user: @user, idempotency_key: "pc-key", request_fingerprint: "pc-fp", request_kind: "apply", selected_item_ids: [ item.id ], status: "completed", completed_at: Time.current)

    error = assert_raises(ActiveRecord::IrreversibleMigration) { AllowPurchaseChangeReviews.new.migrate(:down) }
    assert_includes error.message, "Purchase change reviews exist"
    assert MiaActionDraft.exists?(draft.id)
    assert MiaActionItem.exists?(item.id)
    assert MiaActionDraftApplication.exists?(application.id)
    assert accepts?("purchase_change", "change_purchase"), "the constraint was not rolled back"
  end

  test "rollback also refuses on a lone purchase item and never touches other reviews" do
    other = create_draft("asset_plan")
    other.mia_action_items.create!(action_type: "update_account", position: 0, label: "Account")
    purchase = create_draft("purchase_change")
    purchase.mia_action_items.create!(action_type: "change_purchase", position: 0, label: "Change Target")

    assert_raises(ActiveRecord::IrreversibleMigration) { AllowPurchaseChangeReviews.new.migrate(:down) }
    assert_equal 1, other.reload.mia_action_items.count
    assert_equal 1, purchase.reload.mia_action_items.count
  end

  private

  def create_draft(type)
    @household.mia_action_drafts.create!(requested_by_user: @user, draft_type: type, year: 2026, title: "Review", summary: "Summary", source_prompt: "Prompt")
  end

  # The database itself decides: insert inside a savepoint and roll it back.
  def accepts?(draft_type, action_type)
    ApplicationRecord.transaction(requires_new: true) do
      draft = @household.mia_action_drafts.create!(requested_by_user: @user, draft_type: draft_type, year: 2026, title: "Probe", summary: "Probe", source_prompt: "Probe")
      draft.mia_action_items.create!(action_type: action_type, position: 0, label: "Probe")
      raise ActiveRecord::Rollback
    end
    true
  rescue ActiveRecord::StatementInvalid
    false
  end
end
