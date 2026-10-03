# frozen_string_literal: true

class CreateCohortRolloutFoundation < ActiveRecord::Migration[8.1]
  OPEN_STATUSES = %w[planned active paused].freeze

  def up
    create_rollouts!
    create_waves!
    create_participants!
    create_transitions!
    add_cross_record_constraints!
    add_cohort_lifecycle_guard_triggers!
    add_immutability_triggers!
    add_plan_append_guards!
    add_transition_append_guard!
  end

  def down
    %i[cohort_rollout_transitions cohort_rollout_participants cohort_rollout_waves cohort_rollouts].each do |table|
      execute "LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE"
      next unless select_value("SELECT 1 FROM #{table} LIMIT 1").present?

      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove immutable cohort rollout evidence after rollout plans have been recorded"
    end

    execute "DROP TRIGGER IF EXISTS cohorts_open_rollout_lifecycle_guard ON cohorts"
    drop_table :cohort_rollout_transitions
    drop_table :cohort_rollout_participants
    drop_table :cohort_rollout_waves
    drop_table :cohort_rollouts
    execute "DROP FUNCTION IF EXISTS prevent_cohort_rollout_transition_mutation()"
    execute "DROP FUNCTION IF EXISTS enforce_cohort_rollout_transition_append()"
    execute "DROP FUNCTION IF EXISTS prevent_cohort_rollout_participant_mutation()"
    execute "DROP FUNCTION IF EXISTS prevent_cohort_rollout_plan_append()"
    execute "DROP FUNCTION IF EXISTS enforce_cohort_rollout_participant_limit()"
    execute "DROP FUNCTION IF EXISTS prevent_cohort_rollout_wave_mutation()"
    execute "DROP FUNCTION IF EXISTS protect_cohort_rollout_identity()"
    execute "DROP FUNCTION IF EXISTS enforce_cohort_rollout_cohort_lifecycle()"
    execute "DROP FUNCTION IF EXISTS prevent_cohort_closure_with_open_rollout()"
  end

  private

  def create_rollouts!
    create_table :cohort_rollouts do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :target_cohort_release, null: false,
        foreign_key: { to_table: :cohort_releases, on_delete: :restrict },
        index: { name: "idx_cohort_rollouts_target_release" }
      t.references :rollback_cohort_release,
        foreign_key: { to_table: :cohort_releases, on_delete: :restrict },
        index: { name: "idx_cohort_rollouts_rollback_release" }
      t.references :planned_by_user, null: false,
        foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :planned_by_role_snapshot, null: false
      t.string :status, null: false, default: "planned"
      t.integer :current_wave_position, null: false, default: 0
      t.datetime :planned_at, null: false
      t.datetime :activated_at
      t.datetime :paused_at
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.datetime :rolled_back_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :cohort_rollouts, %i[id cohort_id coach_workspace_id], unique: true,
      name: "idx_cohort_rollouts_id_cohort_workspace"
    add_index :cohort_rollouts, %i[cohort_id created_at id], name: "idx_cohort_rollouts_history"
    add_index :cohort_rollouts, :cohort_id, unique: true, where: "status IN ('planned', 'active', 'paused')",
      name: "idx_cohort_rollouts_one_open"

    add_check_constraint :cohort_rollouts,
      "status IN ('planned', 'active', 'paused', 'completed', 'cancelled', 'rolled_back')",
      name: "cohort_rollouts_status_valid"
    add_check_constraint :cohort_rollouts,
      "planned_by_role_snapshot IN ('platform_admin', 'owner', 'reviewer')",
      name: "cohort_rollouts_actor_role_valid"
    add_check_constraint :cohort_rollouts,
      "current_wave_position BETWEEN 0 AND 25",
      name: "cohort_rollouts_wave_position_bounded"
    add_check_constraint :cohort_rollouts,
      "(status = 'rolled_back' AND rollback_cohort_release_id IS NOT NULL AND rolled_back_at IS NOT NULL) OR " \
        "(status <> 'rolled_back' AND rollback_cohort_release_id IS NULL AND rolled_back_at IS NULL)",
      name: "cohort_rollouts_rollback_shape"
    add_check_constraint :cohort_rollouts, <<~SQL.squish,
      (status = 'planned' AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND
        cancelled_at IS NULL AND rolled_back_at IS NULL) OR
      (status = 'active' AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NULL AND
        cancelled_at IS NULL AND rolled_back_at IS NULL) OR
      (status = 'paused' AND activated_at IS NOT NULL AND paused_at IS NOT NULL AND completed_at IS NULL AND
        cancelled_at IS NULL AND rolled_back_at IS NULL) OR
      (status = 'completed' AND activated_at IS NOT NULL AND paused_at IS NULL AND completed_at IS NOT NULL AND
        cancelled_at IS NULL AND rolled_back_at IS NULL) OR
      (status = 'cancelled' AND activated_at IS NULL AND paused_at IS NULL AND completed_at IS NULL AND
        cancelled_at IS NOT NULL AND rolled_back_at IS NULL) OR
      (status = 'rolled_back' AND activated_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL AND
        rolled_back_at IS NOT NULL)
    SQL
      name: "cohort_rollouts_lifecycle_timestamps"
  end

  def create_waves!
    create_table :cohort_rollout_waves do |t|
      t.references :cohort_rollout, null: false, foreign_key: { on_delete: :restrict }
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.integer :position, null: false
      t.string :name, null: false
      t.timestamps
    end

    add_index :cohort_rollout_waves, %i[cohort_rollout_id position], unique: true,
      name: "idx_cohort_rollout_waves_position"
    add_index :cohort_rollout_waves, %i[id cohort_rollout_id cohort_id coach_workspace_id], unique: true,
      name: "idx_rollout_waves_scope"
    add_check_constraint :cohort_rollout_waves, "position BETWEEN 1 AND 25",
      name: "cohort_rollout_waves_position_bounded"
    add_check_constraint :cohort_rollout_waves, "char_length(name) BETWEEN 1 AND 80",
      name: "cohort_rollout_waves_name_bounded"
  end

  def create_participants!
    create_table :cohort_rollout_participants do |t|
      t.references :cohort_rollout, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort_rollout_wave, null: false, foreign_key: { on_delete: :restrict }
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.timestamps
    end

    add_index :cohort_rollout_participants, %i[cohort_rollout_id user_id], unique: true,
      name: "idx_rollout_participants_user"
    add_index :cohort_rollout_participants, %i[cohort_rollout_id cohort_rollout_wave_id],
      name: "idx_rollout_participants_wave"
    add_index :cohort_rollout_participants, %i[id cohort_rollout_id cohort_id coach_workspace_id], unique: true,
      name: "idx_rollout_participants_scope"
  end

  def create_transitions!
    create_table :cohort_rollout_transitions do |t|
      t.references :cohort_rollout, null: false, foreign_key: { on_delete: :restrict }
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :actor_user, null: false,
        foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :actor_role_snapshot, null: false
      t.string :event_type, null: false
      t.string :from_status
      t.string :to_status, null: false
      t.integer :from_wave_position
      t.integer :to_wave_position
      t.string :readiness_digest
      t.references :rollback_cohort_release,
        foreign_key: { to_table: :cohort_releases, on_delete: :restrict },
        index: { name: "idx_rollout_transitions_rollback_release" }
      t.boolean :participant_runtime_changed, null: false, default: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :cohort_rollout_transitions, %i[cohort_rollout_id occurred_at id],
      name: "idx_rollout_transitions_history"
    add_index :cohort_rollout_transitions, %i[cohort_rollout_id id],
      name: "idx_rollout_transitions_canonical_order"
    add_index :cohort_rollout_transitions, %i[id cohort_id coach_workspace_id], unique: true,
      name: "idx_rollout_transitions_scope"
    add_index :cohort_rollout_transitions, %i[id actor_user_id actor_role_snapshot], unique: true,
      name: "idx_rollout_transitions_actor"

    add_check_constraint :cohort_rollout_transitions,
      "actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer')",
      name: "cohort_rollout_transitions_actor_role_valid"
    add_check_constraint :cohort_rollout_transitions,
      "event_type IN ('planned', 'activated', 'advanced', 'paused', 'resumed', 'completed', 'cancelled', 'rolled_back')",
      name: "cohort_rollout_transitions_event_valid"
    add_check_constraint :cohort_rollout_transitions,
      "to_status IN ('planned', 'active', 'paused', 'completed', 'cancelled', 'rolled_back') AND " \
        "(from_status IS NULL OR from_status IN ('planned', 'active', 'paused', 'completed', 'cancelled', 'rolled_back'))",
      name: "cohort_rollout_transitions_status_valid"
    add_check_constraint :cohort_rollout_transitions,
      "(from_wave_position IS NULL OR from_wave_position BETWEEN 0 AND 25) AND " \
        "(to_wave_position IS NULL OR to_wave_position BETWEEN 0 AND 25)",
      name: "cohort_rollout_transitions_wave_positions_bounded"
    add_check_constraint :cohort_rollout_transitions, "participant_runtime_changed = FALSE",
      name: "cohort_rollout_transitions_runtime_unchanged"
    add_check_constraint :cohort_rollout_transitions,
      "(event_type IN ('activated', 'advanced', 'completed') AND readiness_digest ~ '^[0-9a-f]{64}$') OR " \
        "(event_type NOT IN ('activated', 'advanced', 'completed') AND readiness_digest IS NULL)",
      name: "cohort_rollout_transitions_readiness_evidence"
    add_check_constraint :cohort_rollout_transitions,
      "(event_type = 'rolled_back' AND rollback_cohort_release_id IS NOT NULL) OR " \
        "(event_type <> 'rolled_back' AND rollback_cohort_release_id IS NULL)",
      name: "cohort_rollout_transitions_rollback_shape"
    add_check_constraint :cohort_rollout_transitions, <<~SQL.squish,
      (event_type = 'planned' AND from_status IS NULL AND to_status = 'planned' AND
        from_wave_position IS NULL AND to_wave_position = 0) OR
      (event_type = 'activated' AND from_status = 'planned' AND to_status = 'active' AND
        from_wave_position = 0 AND to_wave_position = 1) OR
      (event_type = 'advanced' AND from_status = 'active' AND to_status = 'active' AND
        from_wave_position >= 1 AND to_wave_position = from_wave_position + 1) OR
      (event_type = 'completed' AND from_status = 'active' AND to_status = 'completed' AND
        from_wave_position >= 1 AND to_wave_position = from_wave_position) OR
      (event_type = 'paused' AND from_status = 'active' AND to_status = 'paused' AND
        from_wave_position >= 1 AND to_wave_position = from_wave_position) OR
      (event_type = 'resumed' AND from_status = 'paused' AND to_status = 'active' AND
        from_wave_position >= 1 AND to_wave_position = from_wave_position) OR
      (event_type = 'cancelled' AND from_status = 'planned' AND to_status = 'cancelled' AND
        from_wave_position = 0 AND to_wave_position = 0) OR
      (event_type = 'rolled_back' AND from_status IN ('active', 'paused') AND to_status = 'rolled_back' AND
        from_wave_position >= 1 AND to_wave_position = from_wave_position)
    SQL
      name: "cohort_rollout_transitions_event_shape"
  end

  def add_cross_record_constraints!
    add_composite_fk :cohort_rollouts, %i[cohort_id coach_workspace_id], :cohorts,
      %i[id coach_workspace_id], "fk_cohort_rollouts_cohort_workspace"
    add_composite_fk :cohort_rollouts, %i[target_cohort_release_id cohort_id coach_workspace_id], :cohort_releases,
      %i[id cohort_id coach_workspace_id], "fk_cohort_rollouts_target_release"
    add_composite_fk :cohort_rollouts, %i[rollback_cohort_release_id cohort_id coach_workspace_id], :cohort_releases,
      %i[id cohort_id coach_workspace_id], "fk_cohort_rollouts_rollback_release"

    %i[cohort_rollout_waves cohort_rollout_participants cohort_rollout_transitions].each do |table|
      add_composite_fk table, %i[cohort_rollout_id cohort_id coach_workspace_id], :cohort_rollouts,
        %i[id cohort_id coach_workspace_id], "fk_#{table}_rollout"
    end
    add_composite_fk :cohort_rollout_participants,
      %i[cohort_rollout_wave_id cohort_rollout_id cohort_id coach_workspace_id], :cohort_rollout_waves,
      %i[id cohort_rollout_id cohort_id coach_workspace_id], "fk_rollout_participants_wave"
    add_composite_fk :cohort_rollout_transitions,
      %i[rollback_cohort_release_id cohort_id coach_workspace_id], :cohort_releases,
      %i[id cohort_id coach_workspace_id], "fk_rollout_transitions_rollback_release"
  end

  def add_composite_fk(from_table, columns, to_table, primary_keys, name)
    execute <<~SQL
      ALTER TABLE #{from_table}
      ADD CONSTRAINT #{name}
      FOREIGN KEY (#{columns.join(', ')})
      REFERENCES #{to_table} (#{primary_keys.join(', ')})
      ON DELETE RESTRICT
    SQL
  end

  def add_immutability_triggers!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_cohort_rollout_identity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'cohort rollouts cannot be deleted'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF (OLD.id, OLD.coach_workspace_id, OLD.cohort_id, OLD.target_cohort_release_id,
            OLD.planned_by_user_id, OLD.planned_by_role_snapshot, OLD.planned_at, OLD.created_at)
           IS DISTINCT FROM
           (NEW.id, NEW.coach_workspace_id, NEW.cohort_id, NEW.target_cohort_release_id,
            NEW.planned_by_user_id, NEW.planned_by_role_snapshot, NEW.planned_at, NEW.created_at) THEN
          RAISE EXCEPTION 'cohort rollout plan identity is immutable'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_rollouts_protect_identity
      BEFORE UPDATE OR DELETE ON cohort_rollouts
      FOR EACH ROW
      EXECUTE FUNCTION protect_cohort_rollout_identity()
    SQL

    add_full_immutability_trigger!(
      table: :cohort_rollout_waves,
      function: :prevent_cohort_rollout_wave_mutation,
      trigger: :cohort_rollout_waves_immutable,
      message: "cohort rollout waves are immutable"
    )
    add_full_immutability_trigger!(
      table: :cohort_rollout_participants,
      function: :prevent_cohort_rollout_participant_mutation,
      trigger: :cohort_rollout_participants_immutable,
      message: "cohort rollout participants are immutable"
    )
    add_participant_limit_trigger!
    add_full_immutability_trigger!(
      table: :cohort_rollout_transitions,
      function: :prevent_cohort_rollout_transition_mutation,
      trigger: :cohort_rollout_transitions_immutable,
      message: "cohort rollout transitions are immutable"
    )
  end

  def add_cohort_lifecycle_guard_triggers!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_cohort_closure_with_open_rollout()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.status IN ('completed', 'archived')
           AND OLD.status IS DISTINCT FROM NEW.status
           AND EXISTS (
             SELECT 1 FROM cohort_rollouts
             WHERE cohort_id = NEW.id
               AND coach_workspace_id = NEW.coach_workspace_id
               AND status IN ('planned', 'active', 'paused')
           ) THEN
          RAISE EXCEPTION 'cohorts with an open rollout cannot be completed or archived'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohorts_open_rollout_lifecycle_guard
      BEFORE UPDATE OF status ON cohorts
      FOR EACH ROW
      EXECUTE FUNCTION prevent_cohort_closure_with_open_rollout()
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_rollout_cohort_lifecycle()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        cohort_status varchar;
      BEGIN
        SELECT status INTO cohort_status
        FROM cohorts
        WHERE id = NEW.cohort_id AND coach_workspace_id = NEW.coach_workspace_id
        FOR UPDATE;
        IF cohort_status IN ('completed', 'archived') THEN
          RAISE EXCEPTION 'cannot open a rollout for a completed or archived cohort'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_rollouts_cohort_lifecycle_guard
      BEFORE INSERT ON cohort_rollouts
      FOR EACH ROW
      EXECUTE FUNCTION enforce_cohort_rollout_cohort_lifecycle()
    SQL
  end

  def add_full_immutability_trigger!(table:, function:, trigger:, message:)
    execute <<~SQL
      CREATE OR REPLACE FUNCTION #{function}()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION '#{message}'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW
      EXECUTE FUNCTION #{function}()
    SQL
  end

  def add_participant_limit_trigger!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_rollout_participant_limit()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM 1 FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id FOR UPDATE;
        IF (SELECT COUNT(*) FROM cohort_rollout_participants
            WHERE cohort_rollout_id = NEW.cohort_rollout_id) >= 500 THEN
          RAISE EXCEPTION 'cohort rollout plans support at most 500 participants'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_rollout_participants_limit
      BEFORE INSERT ON cohort_rollout_participants
      FOR EACH ROW
      EXECUTE FUNCTION enforce_cohort_rollout_participant_limit()
    SQL
  end

  def add_plan_append_guards!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_cohort_rollout_plan_append()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM 1 FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id FOR UPDATE;
        IF EXISTS (
          SELECT 1 FROM cohort_rollout_transitions
          WHERE cohort_rollout_id = NEW.cohort_rollout_id
        ) THEN
          RAISE EXCEPTION 'cohort rollout plan rows cannot be appended after planning completes'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    %i[cohort_rollout_waves cohort_rollout_participants].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_prevent_append
        BEFORE INSERT ON #{table}
        FOR EACH ROW
        EXECUTE FUNCTION prevent_cohort_rollout_plan_append()
      SQL
    end
  end

  def add_transition_append_guard!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_rollout_transition_append()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        rollout_status varchar;
        rollout_wave_position integer;
        rollout_rollback_release_id bigint;
        previous_transition_id bigint;
        previous_status varchar;
        previous_wave_position integer;
      BEGIN
        SELECT status, current_wave_position, rollback_cohort_release_id
        INTO rollout_status, rollout_wave_position, rollout_rollback_release_id
        FROM cohort_rollouts
        WHERE id = NEW.cohort_rollout_id
        FOR UPDATE;

        SELECT id, to_status, to_wave_position
        INTO previous_transition_id, previous_status, previous_wave_position
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = NEW.cohort_rollout_id
        ORDER BY id DESC
        LIMIT 1;

        IF previous_transition_id IS NULL THEN
          IF NEW.event_type <> 'planned' THEN
            RAISE EXCEPTION 'the first rollout transition must be planned'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF NEW.id <= previous_transition_id
           OR NEW.event_type = 'planned'
           OR NEW.from_status IS DISTINCT FROM previous_status
           OR NEW.from_wave_position IS DISTINCT FROM previous_wave_position THEN
          RAISE EXCEPTION 'rollout transitions must append one contiguous canonical tail'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.to_status IS DISTINCT FROM rollout_status
           OR NEW.to_wave_position IS DISTINCT FROM rollout_wave_position
           OR NEW.rollback_cohort_release_id IS DISTINCT FROM rollout_rollback_release_id THEN
          RAISE EXCEPTION 'appended rollout transition must match the current rollout state'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_rollout_transitions_enforce_append
      BEFORE INSERT ON cohort_rollout_transitions
      FOR EACH ROW
      EXECUTE FUNCTION enforce_cohort_rollout_transition_append()
    SQL
  end
end
