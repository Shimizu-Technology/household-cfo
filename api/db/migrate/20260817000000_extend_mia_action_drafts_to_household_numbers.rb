class ExtendMiaActionDraftsToHouseholdNumbers < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule')",
      name: "mia_action_drafts_type_valid"

    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', 'update_setup_value', 'upsert_income_schedule_entry')",
      name: "mia_action_items_action_type_valid"
  end

  def down
    has_extended_drafts = select_value(<<~SQL)
      SELECT EXISTS (
        SELECT 1
        FROM mia_action_drafts
        WHERE draft_type <> 'budget_edit'
      )
    SQL
    if ActiveRecord::Type::Boolean.new.cast(has_extended_drafts)
      raise ActiveRecord::IrreversibleMigration,
        "Household or income Mia drafts exist and cannot be represented by the previous constraints"
    end

    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category')",
      name: "mia_action_items_action_type_valid"

    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit')",
      name: "mia_action_drafts_type_valid"
  end
end
