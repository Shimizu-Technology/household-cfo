class AddTrackedGoalLifecycle < ActiveRecord::Migration[8.1]
  def change
    add_column :goals, :record_kind, :string, null: false, default: "tracked"
    add_column :goals, :active, :boolean, null: false, default: true
    add_column :goals, :archived_at, :datetime
    add_column :goals, :target_amount_known, :boolean, null: false, default: false
    add_column :goals, :current_amount_known, :boolean, null: false, default: false
    add_column :goals, :target_on, :date
    add_column :goals, :source_type, :string, null: false, default: "manual_ui"
    add_column :goals, :source_metadata, :jsonb, null: false, default: {}

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE goals
          SET record_kind = 'policy',
              source_type = 'setup'
          WHERE goal_type IN ('runway', 'transition')
        SQL
        execute <<~SQL.squish
          UPDATE goals
          SET target_amount_known = TRUE
          WHERE target_amount_cents <> 0
        SQL
        execute <<~SQL.squish
          UPDATE goals
          SET current_amount_known = TRUE
          WHERE current_amount_cents <> 0
        SQL
      end
    end

    add_index :goals, [ :household_id, :active ], name: "index_goals_on_household_id_and_active"
    add_index :goals, [ :household_id, :record_kind, :priority ], name: "index_goals_on_kind_and_priority"
    add_index :goals, "household_id, LOWER(label), goal_type", unique: true,
      where: "record_kind = 'tracked' AND active = TRUE",
      name: "index_goals_on_active_tracked_identity"
    add_check_constraint :goals, "record_kind IN ('tracked', 'policy')", name: "goals_record_kind_valid"
    add_check_constraint :goals, "source_type IN ('manual_ui', 'mia', 'document_import', 'setup')", name: "goals_source_type_valid"
    add_check_constraint :goals,
      "(active = TRUE AND archived_at IS NULL) OR (active = FALSE AND archived_at IS NOT NULL)",
      name: "goals_archive_state_valid"
    add_check_constraint :goals,
      "target_amount_known = TRUE OR target_amount_cents = 0",
      name: "goals_unknown_target_is_zero"
    add_check_constraint :goals,
      "current_amount_known = TRUE OR current_amount_cents = 0",
      name: "goals_unknown_current_is_zero"
  end
end
