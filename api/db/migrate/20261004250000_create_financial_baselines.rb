class CreateFinancialBaselines < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_baseline_heads do |t|
      t.references :household, null: false, foreign_key: true
      t.references :participant_user, null: false, foreign_key: { to_table: :users }
      t.bigint :approved_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :financial_baseline_heads, [ :household_id, :participant_user_id ], unique: true, name: "financial_baseline_participant_identity"
    add_index :financial_baseline_heads, [ :id, :household_id ], unique: true, name: "financial_baseline_head_household_identity"
    add_index :financial_baseline_heads, [ :id, :participant_user_id, :household_id ], unique: true, name: "financial_baseline_head_actor_identity"
    create_table :financial_baseline_versions do |t|
      t.references :household, null: false, foreign_key: true
      t.references :financial_baseline_head, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.bigint :supersedes_id
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.date :window_start_on, null: false
      t.date :window_end_on, null: false
      t.string :coverage_status, null: false
      t.string :calculation_version, null: false
      t.string :digest, null: false
      t.jsonb :snapshot, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :financial_baseline_versions, [ :financial_baseline_head_id, :version_number ], unique: true, name: "financial_baseline_version_sequence"
    add_index :financial_baseline_versions, [ :id, :financial_baseline_head_id, :household_id ], unique: true, name: "financial_baseline_version_head_identity"
    add_foreign_key :financial_baseline_versions, :financial_baseline_heads, column: [ :financial_baseline_head_id, :household_id ], primary_key: [ :id, :household_id ], name: "financial_baseline_version_household_scope"
    add_foreign_key :financial_baseline_versions, :financial_baseline_heads, column: [ :financial_baseline_head_id, :approved_by_user_id, :household_id ], primary_key: [ :id, :participant_user_id, :household_id ], name: "financial_baseline_version_actual_participant"
    add_foreign_key :financial_baseline_heads, :financial_baseline_versions, column: [ :approved_version_id, :id, :household_id ], primary_key: [ :id, :financial_baseline_head_id, :household_id ], name: "financial_baseline_approved_head_scope"
    add_foreign_key :financial_baseline_versions, :financial_baseline_versions, column: [ :supersedes_id, :financial_baseline_head_id, :household_id ], primary_key: [ :id, :financial_baseline_head_id, :household_id ], name: "financial_baseline_supersedes_head_scope"
    add_check_constraint :financial_baseline_versions, "window_end_on >= window_start_on AND version_number > 0", name: "financial_baseline_window_version"
    add_check_constraint :financial_baseline_versions, "coverage_status IN ('complete', 'partial', 'manual')", name: "financial_baseline_coverage_status"
    reversible do |direction|
      direction.up do
        execute "CREATE TRIGGER financial_baseline_versions_immutable BEFORE UPDATE OR DELETE ON financial_baseline_versions FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()"
        execute "CREATE TRIGGER financial_baseline_heads_scope_immutable BEFORE UPDATE OR DELETE ON financial_baseline_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable()"
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS financial_baseline_versions_immutable ON financial_baseline_versions"
        execute "DROP TRIGGER IF EXISTS financial_baseline_heads_scope_immutable ON financial_baseline_heads"
      end
    end
  end
end
