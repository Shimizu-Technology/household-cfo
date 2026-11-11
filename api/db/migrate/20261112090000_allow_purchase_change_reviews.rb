# A confirmed purchase can be changed or taken out of spending from the chat.
# The review is a Mia card like the others; this only adds its type.
class AllowPurchaseChangeReviews < ActiveRecord::Migration[8.1]
  DRAFT_TYPES = %w[budget_edit household_setup income_schedule debt_plan asset_plan goal_plan action_plan purchase_change].freeze
  ACTION_TYPES = %w[
    create_category update_category update_allocation archive_category restore_category
    update_setup_value upsert_income_schedule_entry create_income_source update_income_source
    archive_income_source restore_income_source create_income_schedule_entry update_income_schedule_entry
    delete_income_schedule_entry create_debt update_debt archive_debt restore_debt update_debt_tracking
    create_account update_account archive_account restore_account link_plaid_account reconcile_plaid_account unlink_plaid_account
    create_goal update_goal archive_goal restore_goal update_runway_policy update_transition_policy update_household_profile confirm_household_setup
  ].freeze

  def up
    replace_constraints(DRAFT_TYPES, ACTION_TYPES + [ "change_purchase" ])
  end

  def down
    # Purchase-change reviews hold her approved edits and the history that
    # points at them. Dropping them would delete application records while the
    # changed purchase stays. Never discard that to restore the older schema.
    if select_value("SELECT EXISTS (SELECT 1 FROM mia_action_drafts WHERE draft_type = 'purchase_change') OR EXISTS (SELECT 1 FROM mia_action_items WHERE action_type = 'change_purchase')")
      raise ActiveRecord::IrreversibleMigration, "Purchase change reviews exist. Preserve and review them before rolling back."
    end
    replace_constraints(DRAFT_TYPES - [ "purchase_change" ], ACTION_TYPES)
  end

  private

  def replace_constraints(draft_types, action_types)
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts, "draft_type IN (#{quoted(draft_types)})", name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items, "action_type IN (#{quoted(action_types)})", name: "mia_action_items_action_type_valid"
  end

  def quoted(values) = values.map { |value| connection.quote(value) }.join(", ")
end
