class AddGoalActionReviewTypes < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule', 'debt_plan', 'asset_plan', 'goal_plan')",
      name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', 'update_setup_value', 'upsert_income_schedule_entry', 'create_income_source', 'update_income_source', 'archive_income_source', 'restore_income_source', 'create_income_schedule_entry', 'update_income_schedule_entry', 'delete_income_schedule_entry', 'create_debt', 'update_debt', 'archive_debt', 'restore_debt', 'update_debt_tracking', 'create_account', 'update_account', 'archive_account', 'restore_account', 'link_plaid_account', 'reconcile_plaid_account', 'unlink_plaid_account', 'create_goal', 'update_goal', 'archive_goal', 'restore_goal')",
      name: "mia_action_items_action_type_valid"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Pending goal reviews cannot be represented by the former action schema"
  end
end
