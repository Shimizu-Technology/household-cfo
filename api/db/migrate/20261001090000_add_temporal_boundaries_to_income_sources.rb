class AddTemporalBoundariesToIncomeSources < ActiveRecord::Migration[8.1]
  OLD_INDEX = "index_income_sources_on_household_source_type_label"
  NEW_INDEX = "index_income_sources_on_household_type_lower_label"

  def up
    add_column :income_sources, :starts_on, :date
    add_column :income_sources, :ends_on, :date
    add_check_constraint :income_sources,
      "starts_on IS NULL OR ends_on IS NULL OR starts_on < ends_on",
      name: "income_sources_temporal_bounds_valid"

    duplicate_groups = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM (
        SELECT household_id, source_type, LOWER(label)
        FROM income_sources
        WHERE active = TRUE
        GROUP BY household_id, source_type, LOWER(label)
        HAVING COUNT(*) > 1
      ) duplicate_income_sources
    SQL
    if duplicate_groups.positive?
      raise ActiveRecord::MigrationError,
        "Cannot enforce case-insensitive income source names: #{duplicate_groups} household/type group(s) contain duplicate labels"
    end

    remove_index :income_sources, name: OLD_INDEX
    add_index :income_sources,
      "household_id, source_type, LOWER(label)",
      unique: true,
      where: "active = TRUE",
      name: NEW_INDEX

    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', " \
      "'update_setup_value', 'upsert_income_schedule_entry', 'create_income_source', 'update_income_source', " \
      "'archive_income_source', 'restore_income_source', 'create_income_schedule_entry', 'update_income_schedule_entry', " \
      "'delete_income_schedule_entry')",
      name: "mia_action_items_action_type_valid"
  end

  def down
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', 'update_setup_value', 'upsert_income_schedule_entry')",
      name: "mia_action_items_action_type_valid"
    remove_index :income_sources, name: NEW_INDEX
    add_index :income_sources,
      [ :household_id, :source_type, :label ],
      unique: true,
      name: OLD_INDEX
    remove_check_constraint :income_sources, name: "income_sources_temporal_bounds_valid"
    remove_column :income_sources, :ends_on
    remove_column :income_sources, :starts_on
  end
end
