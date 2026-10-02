# frozen_string_literal: true

class CreateCoachOperationExecutions < ActiveRecord::Migration[8.1]
  def up
    add_index :cohort_releases, %i[id released_by_user_id actor_role_snapshot], unique: true,
      name: "idx_cohort_releases_operation_actor"

    create_table :coach_operation_executions do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :actor_role_snapshot, null: false
      t.string :operation_key, null: false
      t.integer :operation_version, null: false
      t.string :source, null: false, default: "api"
      t.string :request_key, null: false
      t.string :invocation_fingerprint, null: false
      t.string :request_fingerprint, null: false
      t.jsonb :normalized_input, null: false, default: {}
      t.string :normalized_input_digest, null: false
      t.jsonb :before_snapshot, null: false, default: {}
      t.string :before_snapshot_digest, null: false
      t.jsonb :predicted_after_snapshot, null: false, default: {}
      t.string :predicted_after_snapshot_digest, null: false
      t.jsonb :after_snapshot, null: false, default: {}
      t.string :after_snapshot_digest, null: false
      t.references :cohort_release, null: false, foreign_key: { on_delete: :restrict },
        index: { unique: true, name: "idx_coach_operations_release_unique" }
      t.datetime :completed_at, null: false
      t.timestamps
    end

    add_index :coach_operation_executions, %i[cohort_id request_key], unique: true,
      name: "idx_coach_operations_cohort_request"
    add_index :coach_operation_executions, %i[id cohort_id coach_workspace_id], unique: true,
      name: "idx_coach_operations_id_cohort_workspace"
    add_index :coach_operation_executions, %i[cohort_id completed_at id],
      name: "idx_coach_operations_history"

    add_check_constraint :coach_operation_executions,
      "operation_version = 1", name: "coach_operations_version_supported"
    add_check_constraint :coach_operation_executions,
      "actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer')",
      name: "coach_operations_actor_role_valid"
    add_check_constraint :coach_operation_executions,
      "source = 'api'", name: "coach_operations_source_valid"
    add_check_constraint :coach_operation_executions,
      "operation_key IN ('cohort.release.seal', 'cohort.release.restore')",
      name: "coach_operations_key_valid"
    add_check_constraint :coach_operation_executions,
      "char_length(request_key) BETWEEN 1 AND 100",
      name: "coach_operations_request_key_bounded"
    add_check_constraint :coach_operation_executions,
      "invocation_fingerprint ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$' AND " \
        "normalized_input_digest ~ '^[0-9a-f]{64}$' AND before_snapshot_digest ~ '^[0-9a-f]{64}$' AND " \
        "predicted_after_snapshot_digest ~ '^[0-9a-f]{64}$' AND after_snapshot_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_operations_digest_shape"
    add_check_constraint :coach_operation_executions,
      "jsonb_typeof(normalized_input) = 'object' AND jsonb_typeof(before_snapshot) = 'object' AND " \
        "jsonb_typeof(predicted_after_snapshot) = 'object' AND jsonb_typeof(after_snapshot) = 'object'",
      name: "coach_operations_json_shape"
    add_check_constraint :coach_operation_executions,
      "octet_length(normalized_input::text) <= 16384 AND octet_length(before_snapshot::text) <= 16384 AND " \
        "octet_length(predicted_after_snapshot::text) <= 16384 AND octet_length(after_snapshot::text) <= 16384",
      name: "coach_operations_json_bounded"

    execute <<~SQL
      ALTER TABLE coach_operation_executions
      ADD CONSTRAINT fk_coach_operations_cohort_workspace
      FOREIGN KEY (cohort_id, coach_workspace_id)
      REFERENCES cohorts (id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE coach_operation_executions
      ADD CONSTRAINT fk_coach_operations_release
      FOREIGN KEY (cohort_release_id, cohort_id, coach_workspace_id)
      REFERENCES cohort_releases (id, cohort_id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE coach_operation_executions
      ADD CONSTRAINT fk_coach_operations_release_actor
      FOREIGN KEY (cohort_release_id, actor_user_id, actor_role_snapshot)
      REFERENCES cohort_releases (id, released_by_user_id, actor_role_snapshot)
      ON DELETE RESTRICT
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_coach_operation_execution_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'coach operation executions are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER coach_operation_executions_immutable
      BEFORE UPDATE OR DELETE ON coach_operation_executions
      FOR EACH ROW
      EXECUTE FUNCTION prevent_coach_operation_execution_mutation()
    SQL
  end

  def down
    execute "LOCK TABLE coach_operation_executions IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM coach_operation_executions LIMIT 1").present?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove immutable coach operation evidence after operations have completed"
    end

    drop_table :coach_operation_executions
    execute "DROP FUNCTION IF EXISTS prevent_coach_operation_execution_mutation()"
    remove_index :cohort_releases, name: "idx_cohort_releases_operation_actor"
  end
end
