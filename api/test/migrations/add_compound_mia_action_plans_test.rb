require "test_helper"
require Rails.root.join("db/migrate/20261002150000_add_compound_mia_action_plans").to_s

class AddCompoundMiaActionPlansTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "compound_migration_#{SecureRandom.hex(4)}",
      email: "compound-migration-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "backfills terminal state for realistic legacy applied and canceled items" do
    applied_at = 3.days.ago.change(usec: 0)
    canceled_at = 2.days.ago.change(usec: 0)
    applied = create_draft(status: "applied", applied_at: applied_at, applied_by_user: @user)
    canceled = create_draft(status: "canceled", canceled_at: canceled_at, canceled_by_user: @user)
    pending = create_draft(status: "pending")
    applied_item = create_item(applied)
    canceled_item = create_item(canceled)
    pending_item = create_item(pending)

    AddCompoundMiaActionPlans.new.backfill_terminal_item_states!

    assert_equal applied_at, applied_item.reload.applied_at
    assert_equal canceled_at, canceled_item.reload.canceled_at
    assert_equal @user, canceled_item.canceled_by_user
    assert_nil pending_item.reload.applied_at
    assert_nil pending_item.canceled_at
  end

  test "rollback is explicit because feature rows cannot be converted safely" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddCompoundMiaActionPlans.new.down
    end

    assert_includes error.message, "per-item terminal state"
    assert_includes error.message, "cannot be safely discarded"
  end

  test "database rejects an application whose draft belongs to another household" do
    other_user = User.create!(
      clerk_id: "compound_other_#{SecureRandom.hex(4)}",
      email: "compound-other-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    other_household = HouseholdFinance::WorkspaceResolver.new(other_user).household
    draft = create_draft(status: "pending")

    assert_raises(ActiveRecord::InvalidForeignKey) do
      MiaActionDraftApplication.insert_all!([ {
        mia_action_draft_id: draft.id,
        household_id: other_household.id,
        user_id: other_user.id,
        idempotency_key: "cross-household",
        request_fingerprint: "f" * 64,
        request_kind: "apply",
        selected_item_ids: [],
        status: "processing",
        response_payload: {},
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  private

  def create_draft(status:, applied_at: nil, applied_by_user: nil, canceled_at: nil, canceled_by_user: nil)
    @household.mia_action_drafts.create!(
      requested_by_user: @user,
      status: status,
      draft_type: "asset_plan",
      year: Date.current.year,
      title: "Legacy #{status} review",
      summary: "Legacy terminal review",
      source_prompt: "Legacy request",
      applied_at: applied_at,
      applied_by_user: applied_by_user,
      canceled_at: canceled_at,
      canceled_by_user: canceled_by_user
    )
  end

  def create_item(draft)
    draft.mia_action_items.create!(
      action_type: "update_account",
      position: 0,
      label: "Legacy account update"
    )
  end
end
