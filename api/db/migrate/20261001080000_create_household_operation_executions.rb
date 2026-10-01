class CreateHouseholdOperationExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :household_operation_executions do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :household_audit_event, null: false, foreign_key: true
      t.references :reviewable, polymorphic: true
      t.string :operation_key, null: false
      t.integer :operation_version, null: false
      t.string :idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :source, null: false
      t.string :status, null: false, default: "completed"
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :normalized_input, null: false, default: {}
      t.jsonb :before_snapshot, null: false, default: {}
      t.jsonb :predicted_after_snapshot, null: false, default: {}
      t.jsonb :after_snapshot, null: false, default: {}
      t.datetime :completed_at, null: false
      t.timestamps
    end

    add_index :household_operation_executions,
      [ :household_id, :idempotency_key ],
      unique: true,
      name: "index_household_operations_on_household_and_idempotency"
    add_index :household_operation_executions, [ :subject_type, :subject_id ], name: "index_household_operations_on_subject"
    add_check_constraint :household_operation_executions, "operation_version > 0", name: "household_operations_version_positive"
    add_check_constraint :household_operation_executions, "source IN ('manual', 'mia')", name: "household_operations_source_valid"
    add_check_constraint :household_operation_executions, "status = 'completed'", name: "household_operations_status_valid"
    add_check_constraint :household_operation_executions, "jsonb_typeof(normalized_input) = 'object'", name: "household_operations_input_object"
    add_check_constraint :household_operation_executions, "jsonb_typeof(before_snapshot) = 'object'", name: "household_operations_before_object"
    add_check_constraint :household_operation_executions, "jsonb_typeof(predicted_after_snapshot) = 'object'", name: "household_operations_predicted_object"
    add_check_constraint :household_operation_executions, "jsonb_typeof(after_snapshot) = 'object'", name: "household_operations_after_object"

    add_column :mia_action_items, :operation_key, :string
    add_column :mia_action_items, :operation_version, :integer
    add_column :mia_action_items, :prepared_operation, :jsonb, null: false, default: {}
    add_column :mia_action_items, :prepared_operation_fingerprint, :string
    add_check_constraint :mia_action_items,
      "(operation_key IS NULL AND operation_version IS NULL AND prepared_operation_fingerprint IS NULL AND prepared_operation = '{}'::jsonb) OR " \
        "(operation_key IS NOT NULL AND operation_version > 0 AND prepared_operation_fingerprint IS NOT NULL AND prepared_operation <> '{}'::jsonb)",
      name: "mia_action_items_operation_identity_complete"
    add_check_constraint :mia_action_items, "jsonb_typeof(prepared_operation) = 'object'", name: "mia_action_items_prepared_operation_object"
  end
end
