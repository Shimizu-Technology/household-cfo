# frozen_string_literal: true

class ActivateCohortReleaseRuntime < ActiveRecord::Migration[8.0]
  def up
    add_reference :cohorts, :active_cohort_release, foreign_key: { to_table: :cohort_releases, on_delete: :restrict }, index: true
    add_reference :cohort_rollouts, :baseline_cohort_release, foreign_key: { to_table: :cohort_releases, on_delete: :restrict }, index: true
    add_column :cohort_rollout_participants, :cohort_membership_id, :bigint
    add_column :cohort_rollout_participants, :membership_started_at, :datetime
    add_index :cohort_rollout_participants, %i[cohort_membership_id membership_started_at],
      name: "idx_rollout_participants_membership_epoch"
    add_check_constraint :cohort_rollout_participants,
      "(cohort_membership_id IS NULL AND membership_started_at IS NULL) OR " \
        "(cohort_membership_id IS NOT NULL AND membership_started_at IS NOT NULL)",
      name: "cohort_rollout_participants_membership_epoch_complete"
    add_index :cohort_releases, %i[id cohort_id], unique: true, name: "idx_cohort_releases_id_cohort"
    add_index :cohort_rollout_transitions, %i[id cohort_rollout_id cohort_id coach_workspace_id],
      unique: true, name: "idx_rollout_transitions_full_scope"

    add_index :cohorts, %i[id coach_workspace_id active_cohort_release_id],
      unique: true, name: "idx_cohorts_active_release_scope"
    add_foreign_key :cohorts, :cohort_releases,
      column: %i[active_cohort_release_id id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_cohorts_active_release_scope", on_delete: :restrict
    add_foreign_key :cohort_rollouts, :cohort_releases,
      column: %i[baseline_cohort_release_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_cohort_rollouts_baseline_release", on_delete: :restrict

    create_table :cohort_release_activation_events do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :from_cohort_release, foreign_key: { to_table: :cohort_releases, on_delete: :restrict }
      t.references :to_cohort_release, null: false, foreign_key: { to_table: :cohort_releases, on_delete: :restrict }
      t.references :cohort_rollout, foreign_key: { on_delete: :restrict }
      t.references :cohort_rollout_transition, foreign_key: { on_delete: :restrict }
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :actor_role_snapshot
      t.string :event_type, null: false
      t.string :request_key, null: false
      t.string :request_fingerprint, null: false
      t.bigint :database_transaction_id, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :cohort_release_activation_events, %i[cohort_id request_key],
      unique: true, name: "idx_release_activation_events_request"
    add_index :cohort_release_activation_events, %i[cohort_id occurred_at id],
      name: "idx_release_activation_events_history"
    add_index :cohort_release_activation_events, %i[id cohort_id coach_workspace_id],
      unique: true, name: "idx_release_activation_events_scope"
    add_foreign_key :cohort_release_activation_events, :cohorts,
      column: %i[cohort_id coach_workspace_id], primary_key: %i[id coach_workspace_id],
      name: "fk_release_activation_events_cohort", on_delete: :restrict
    %i[from_cohort_release_id to_cohort_release_id].each do |column|
      add_foreign_key :cohort_release_activation_events, :cohort_releases,
        column: [ column, :cohort_id, :coach_workspace_id ],
        primary_key: %i[id cohort_id coach_workspace_id],
        name: "fk_release_activation_events_#{column == :from_cohort_release_id ? 'from' : 'to'}", on_delete: :restrict
    end
    add_foreign_key :cohort_release_activation_events, :cohort_rollouts,
      column: %i[cohort_rollout_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_release_activation_events_rollout", on_delete: :restrict
    add_foreign_key :cohort_release_activation_events, :cohort_rollout_transitions,
      column: %i[cohort_rollout_transition_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_release_activation_events_transition", on_delete: :restrict
    add_foreign_key :cohort_release_activation_events, :cohort_rollout_transitions,
      column: %i[cohort_rollout_transition_id cohort_rollout_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_rollout_id cohort_id coach_workspace_id],
      name: "fk_release_activation_events_rollout_transition", on_delete: :restrict
    add_check_constraint :cohort_release_activation_events,
      "event_type IN ('backfill', 'rollout_completed')", name: "release_activation_events_type_valid"
    add_check_constraint :cohort_release_activation_events,
      "request_fingerprint ~ '^[0-9a-f]{64}$' AND char_length(request_key) BETWEEN 1 AND 100",
      name: "release_activation_events_request_valid"
    add_check_constraint :cohort_release_activation_events,
      <<~SQL.squish, name: "release_activation_events_shape"
        (event_type = 'backfill' AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL
          AND actor_user_id IS NULL AND actor_role_snapshot IS NULL)
        OR
        (event_type = 'rollout_completed' AND cohort_rollout_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL
          AND actor_user_id IS NOT NULL AND actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer'))
      SQL

    create_table :cohort_release_exposures do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.bigint :cohort_membership_id, null: false
      t.datetime :membership_started_at, null: false
      t.references :cohort_release, null: false, foreign_key: { on_delete: :restrict }
      t.references :cohort_rollout, foreign_key: { on_delete: :restrict }
      t.references :cohort_rollout_wave, foreign_key: { on_delete: :restrict }
      t.references :cohort_rollout_transition, foreign_key: { on_delete: :restrict }
      t.string :event_type, null: false
      t.string :exposure_key, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :cohort_release_exposures, %i[cohort_id exposure_key], unique: true,
      name: "idx_cohort_release_exposures_key"
    add_index :cohort_release_exposures,
      %i[cohort_id user_id cohort_membership_id membership_started_at occurred_at id],
      name: "idx_cohort_release_exposures_runtime"
    add_index :cohort_release_exposures, %i[cohort_rollout_id cohort_rollout_transition_id user_id],
      unique: true, where: "cohort_rollout_transition_id IS NOT NULL",
      name: "idx_cohort_release_exposures_transition_user"
    add_index :cohort_release_exposures, %i[id cohort_id coach_workspace_id],
      unique: true, name: "idx_cohort_release_exposures_scope"
    add_foreign_key :cohort_release_exposures, :cohorts,
      column: %i[cohort_id coach_workspace_id], primary_key: %i[id coach_workspace_id],
      name: "fk_cohort_release_exposures_cohort", on_delete: :restrict
    add_foreign_key :cohort_release_exposures, :cohort_releases,
      column: %i[cohort_release_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_cohort_release_exposures_release", on_delete: :restrict
    add_foreign_key :cohort_release_exposures, :cohort_rollouts,
      column: %i[cohort_rollout_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_id coach_workspace_id],
      name: "fk_cohort_release_exposures_rollout", on_delete: :restrict
    add_foreign_key :cohort_release_exposures, :cohort_rollout_waves,
      column: %i[cohort_rollout_wave_id cohort_rollout_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_rollout_id cohort_id coach_workspace_id],
      name: "fk_cohort_release_exposures_wave", on_delete: :restrict
    add_foreign_key :cohort_release_exposures, :cohort_rollout_transitions,
      column: %i[cohort_rollout_transition_id cohort_rollout_id cohort_id coach_workspace_id],
      primary_key: %i[id cohort_rollout_id cohort_id coach_workspace_id],
      name: "fk_cohort_release_exposures_transition", on_delete: :restrict
    add_check_constraint :cohort_release_exposures,
      "event_type IN ('wave', 'rollback')", name: "cohort_release_exposures_type_valid"
    add_check_constraint :cohort_release_exposures,
      "char_length(exposure_key) BETWEEN 1 AND 160", name: "cohort_release_exposures_key_bounded"
    add_check_constraint :cohort_release_exposures,
      "cohort_rollout_id IS NOT NULL AND cohort_rollout_wave_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL",
      name: "cohort_release_exposures_rollout_shape"
    add_check_constraint :cohort_rollouts,
      "baseline_cohort_release_id IS NULL OR baseline_cohort_release_id <> target_cohort_release_id",
      name: "cohort_rollouts_distinct_runtime_releases"

    add_reference :chat_messages, :cohort, foreign_key: { on_delete: :restrict }, index: true
    add_reference :chat_messages, :cohort_release, foreign_key: { on_delete: :restrict }, index: true
    add_index :chat_messages, %i[cohort_release_id cohort_id], name: "idx_chat_messages_release_cohort"
    add_foreign_key :chat_messages, :cohort_releases,
      column: %i[cohort_release_id cohort_id], primary_key: %i[id cohort_id],
      name: "fk_chat_messages_release_cohort", on_delete: :restrict
    add_check_constraint :chat_messages,
      "cohort_release_id IS NULL OR cohort_id IS NOT NULL",
      name: "chat_messages_release_attribution_complete"

    remove_check_constraint :coach_operation_executions, name: "coach_operations_version_supported"
    add_check_constraint :coach_operation_executions, "operation_version IN (1, 2)",
      name: "coach_operations_version_supported"

    remove_check_constraint :cohort_rollout_transitions, name: "cohort_rollout_transitions_runtime_unchanged"
    add_check_constraint :cohort_rollout_transitions,
      <<~SQL.squish, name: "cohort_rollout_transitions_runtime_changed_shape"
        event_type IN ('activated', 'advanced', 'completed', 'rolled_back')
        OR participant_runtime_changed = false
      SQL

    install_append_only_guards
    install_runtime_scope_guards
    upgrade_rollout_execution_integrity
    install_deferred_runtime_evidence_integrity
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "participant release exposure and activation evidence is append-only audit history and cannot be safely discarded"
  end

  private

  def install_append_only_guards
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_cohort_runtime_evidence_mutation()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'cohort runtime evidence is append-only'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$
    SQL
    %w[cohort_release_exposures cohort_release_activation_events].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_immutable
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION prevent_cohort_runtime_evidence_mutation()
      SQL
    end
  end

  def install_runtime_scope_guards
    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_cohort_rollout_identity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'cohort rollouts cannot be deleted'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF (OLD.id, OLD.coach_workspace_id, OLD.cohort_id, OLD.target_cohort_release_id,
            OLD.baseline_cohort_release_id, OLD.planned_by_user_id, OLD.planned_by_role_snapshot,
            OLD.planned_at, OLD.created_at)
           IS DISTINCT FROM
           (NEW.id, NEW.coach_workspace_id, NEW.cohort_id, NEW.target_cohort_release_id,
            NEW.baseline_cohort_release_id, NEW.planned_by_user_id, NEW.planned_by_role_snapshot,
            NEW.planned_at, NEW.created_at) THEN
          RAISE EXCEPTION 'cohort rollout plan identity is immutable'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_runtime_scope()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.active_cohort_release_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM cohort_releases
          WHERE id = NEW.active_cohort_release_id
            AND cohort_id = NEW.id
            AND coach_workspace_id = NEW.coach_workspace_id
        ) THEN
          RAISE EXCEPTION 'active cohort release must belong to the cohort and workspace'
            USING ERRCODE = 'foreign_key_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_runtime_scope_guard
      BEFORE INSERT OR UPDATE OF active_cohort_release_id, coach_workspace_id ON cohorts
      FOR EACH ROW EXECUTE FUNCTION enforce_cohort_runtime_scope()
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_release_exposure_membership_epoch()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM cohort_memberships membership
          WHERE membership.id = NEW.cohort_membership_id
            AND membership.cohort_id = NEW.cohort_id
            AND membership.user_id = NEW.user_id
            AND membership.role = 'participant'
            AND membership.created_at = NEW.membership_started_at
        ) THEN
          RAISE EXCEPTION 'release exposure must reference the current participant membership epoch'
            USING ERRCODE = 'foreign_key_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_release_exposures_membership_epoch_guard
      BEFORE INSERT ON cohort_release_exposures
      FOR EACH ROW EXECUTE FUNCTION enforce_cohort_release_exposure_membership_epoch()
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_cohort_rollout_participant_membership_epoch()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        runtime_rollout boolean;
      BEGIN
        SELECT baseline_cohort_release_id IS NOT NULL INTO runtime_rollout
        FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id;
        IF runtime_rollout AND NOT EXISTS (
          SELECT 1 FROM cohort_memberships membership
          WHERE membership.id = NEW.cohort_membership_id
            AND membership.cohort_id = NEW.cohort_id
            AND membership.user_id = NEW.user_id
            AND membership.role = 'participant'
            AND membership.created_at = NEW.membership_started_at
        ) THEN
          RAISE EXCEPTION 'runtime rollout participants must pin the current participant membership epoch'
            USING ERRCODE = 'foreign_key_violation';
        ELSIF NOT runtime_rollout AND
          (NEW.cohort_membership_id IS NOT NULL OR NEW.membership_started_at IS NOT NULL) THEN
          RAISE EXCEPTION 'legacy rollout participants cannot claim runtime membership evidence'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_rollout_participants_membership_epoch_guard
      BEFORE INSERT ON cohort_rollout_participants
      FOR EACH ROW EXECUTE FUNCTION enforce_cohort_rollout_participant_membership_epoch()
    SQL
  end

  def upgrade_rollout_execution_integrity
    definition = select_value(<<~SQL.squish)
      SELECT pg_get_functiondef(to_regprocedure('validate_cohort_rollout_transition_integrity(bigint)'))
    SQL
    marker = <<~SQL.rstrip
      IF transition_record.event_type = 'planned' THEN
          expected_before_snapshot := jsonb_build_object(
    SQL
    runtime_validation = <<~SQL.rstrip
      IF (execution_record.operation_version = 2) IS DISTINCT FROM
         (rollout_record.baseline_cohort_release_id IS NOT NULL) THEN
        RAISE EXCEPTION 'rollout operation version must match its runtime mode'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF execution_record.operation_version = 2 THEN
          IF rollout_record.baseline_cohort_release_id IS NULL
             OR rollout_record.baseline_cohort_release_id = rollout_record.target_cohort_release_id THEN
            RAISE EXCEPTION 'runtime rollout must capture a distinct baseline release'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF transition_record.participant_runtime_changed IS DISTINCT FROM
             (transition_record.event_type IN ('activated', 'advanced', 'completed', 'rolled_back')) THEN
            RAISE EXCEPTION 'runtime change evidence does not match the v2 rollout event'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF transition_record.event_type = 'planned' THEN
            expected_before_snapshot := jsonb_build_object(
              'schema', 'cohort_rollout_state_v2',
              'cohort_id', rollout_record.cohort_id,
              'coach_workspace_id', rollout_record.coach_workspace_id,
              'rollout_id', NULL,
              'status', NULL,
              'current_wave_position', NULL,
              'latest_transition_id', NULL,
              'target_release_id', NULL,
              'rollback_release_id', NULL,
              'latest_release_id', rollout_record.target_cohort_release_id,
              'participant_roster_digest', execution_record.normalized_input->>'expected_roster_digest',
              'participant_runtime_changed', false,
              'active_release_id', rollout_record.baseline_cohort_release_id,
              'baseline_release_id', rollout_record.baseline_cohort_release_id
            );
            expected_predicted_snapshot := jsonb_build_object(
              'schema', 'cohort_rollout_state_v2',
              'cohort_id', rollout_record.cohort_id,
              'coach_workspace_id', rollout_record.coach_workspace_id,
              'rollout_id', NULL,
              'status', transition_record.to_status,
              'current_wave_position', transition_record.to_wave_position,
              'latest_transition_id', NULL,
              'target_release_id', rollout_record.target_cohort_release_id,
              'rollback_release_id', NULL,
              'participant_runtime_changed', false,
              'active_release_id', rollout_record.baseline_cohort_release_id,
              'baseline_release_id', rollout_record.baseline_cohort_release_id,
              'latest_transition_id_pending', true,
              'rollout_id_pending', true
            );
          ELSE
            expected_before_snapshot := jsonb_build_object(
              'schema', 'cohort_rollout_state_v2',
              'cohort_id', rollout_record.cohort_id,
              'coach_workspace_id', rollout_record.coach_workspace_id,
              'rollout_id', transition_record.cohort_rollout_id,
              'status', transition_record.from_status,
              'current_wave_position', transition_record.from_wave_position,
              'latest_transition_id', previous_transition_id,
              'target_release_id', rollout_record.target_cohort_release_id,
              'rollback_release_id', NULL,
              'participant_runtime_changed', false,
              'active_release_id', rollout_record.baseline_cohort_release_id,
              'baseline_release_id', rollout_record.baseline_cohort_release_id
            );
            IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
              expected_before_snapshot := expected_before_snapshot ||
                jsonb_build_object('readiness_digest', transition_record.readiness_digest);
            END IF;
            expected_predicted_snapshot := jsonb_build_object(
              'schema', 'cohort_rollout_state_v2',
              'cohort_id', rollout_record.cohort_id,
              'coach_workspace_id', rollout_record.coach_workspace_id,
              'rollout_id', transition_record.cohort_rollout_id,
              'status', transition_record.to_status,
              'current_wave_position', transition_record.to_wave_position,
              'latest_transition_id', NULL,
              'target_release_id', rollout_record.target_cohort_release_id,
              'rollback_release_id', transition_record.rollback_cohort_release_id,
              'participant_runtime_changed', transition_record.participant_runtime_changed,
              'active_release_id', CASE WHEN transition_record.to_status = 'completed'
                THEN rollout_record.target_cohort_release_id ELSE rollout_record.baseline_cohort_release_id END,
              'baseline_release_id', rollout_record.baseline_cohort_release_id,
              'latest_transition_id_pending', true
            );
          END IF;
          expected_after_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v2',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', transition_record.cohort_rollout_id,
            'status', transition_record.to_status,
            'current_wave_position', transition_record.to_wave_position,
            'latest_transition_id', transition_record.id,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', transition_record.rollback_cohort_release_id,
            'participant_runtime_changed', transition_record.participant_runtime_changed,
            'active_release_id', CASE WHEN transition_record.to_status = 'completed'
              THEN rollout_record.target_cohort_release_id ELSE rollout_record.baseline_cohort_release_id END,
            'baseline_release_id', rollout_record.baseline_cohort_release_id
          );
          IF execution_record.before_snapshot IS DISTINCT FROM expected_before_snapshot
             OR execution_record.predicted_after_snapshot IS DISTINCT FROM expected_predicted_snapshot
             OR execution_record.after_snapshot IS DISTINCT FROM expected_after_snapshot THEN
            RAISE EXCEPTION 'v2 rollout snapshots do not match runtime evidence'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF transition_record.event_type = 'planned' THEN
            IF rollout_record.baseline_cohort_release_id IS DISTINCT FROM (
              SELECT active_cohort_release_id FROM cohorts WHERE id = rollout_record.cohort_id
            ) THEN
              RAISE EXCEPTION 'runtime rollout baseline must match the active cohort release'
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
          ELSIF transition_record.event_type IN ('activated', 'advanced', 'completed') AND EXISTS (
            SELECT 1
            FROM cohort_rollout_participants participant
            LEFT JOIN cohort_memberships membership
              ON membership.id = participant.cohort_membership_id
             AND membership.cohort_id = participant.cohort_id
             AND membership.user_id = participant.user_id
             AND membership.role = 'participant'
             AND membership.created_at = participant.membership_started_at
            WHERE participant.cohort_rollout_id = rollout_record.id
              AND membership.id IS NULL
          ) THEN
            RAISE EXCEPTION 'runtime rollout participant enrollment changed after planning'
              USING ERRCODE = 'integrity_constraint_violation';
          ELSIF transition_record.event_type IN ('activated', 'advanced') THEN
            IF EXISTS (
                 SELECT 1 FROM cohort_release_exposures exposure
                 LEFT JOIN cohort_rollout_participants participant
                   ON participant.cohort_rollout_id = rollout_record.id
                  AND participant.user_id = exposure.user_id
                  AND participant.cohort_rollout_wave_id = exposure.cohort_rollout_wave_id
                 LEFT JOIN cohort_rollout_waves wave
                   ON wave.id = participant.cohort_rollout_wave_id
                  AND wave.cohort_rollout_id = rollout_record.id
                 WHERE exposure.cohort_rollout_transition_id = transition_record.id
                   AND (exposure.event_type <> 'wave'
                     OR exposure.cohort_release_id <> rollout_record.target_cohort_release_id
                     OR participant.id IS NULL
                     OR wave.position <> transition_record.to_wave_position)
               ) OR EXISTS (
                 SELECT 1 FROM cohort_rollout_participants participant
                 JOIN cohort_rollout_waves wave ON wave.id = participant.cohort_rollout_wave_id
                 LEFT JOIN cohort_release_exposures exposure
                   ON exposure.cohort_rollout_transition_id = transition_record.id
                  AND exposure.user_id = participant.user_id
                  AND exposure.cohort_rollout_wave_id = wave.id
                  AND exposure.event_type = 'wave'
                  AND exposure.cohort_release_id = rollout_record.target_cohort_release_id
                 WHERE participant.cohort_rollout_id = rollout_record.id
                   AND wave.position = transition_record.to_wave_position
                   AND exposure.id IS NULL
               ) THEN
              RAISE EXCEPTION 'runtime rollout wave exposure is incomplete'
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
          ELSIF transition_record.event_type = 'completed' THEN
            IF (SELECT active_cohort_release_id FROM cohorts WHERE id = rollout_record.cohort_id)
                 IS DISTINCT FROM rollout_record.target_cohort_release_id
               OR NOT EXISTS (
                 SELECT 1 FROM cohort_release_activation_events event
                 WHERE event.cohort_rollout_transition_id = transition_record.id
                   AND event.to_cohort_release_id = rollout_record.target_cohort_release_id
               ) THEN
              RAISE EXCEPTION 'completed runtime rollout must activate its target release'
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
          ELSIF transition_record.event_type = 'rolled_back' THEN
            IF transition_record.rollback_cohort_release_id IS DISTINCT FROM rollout_record.baseline_cohort_release_id
               OR EXISTS (
                 SELECT 1 FROM cohort_release_exposures exposure
                 WHERE exposure.cohort_rollout_transition_id = transition_record.id
                   AND (exposure.event_type <> 'rollback'
                     OR exposure.cohort_release_id <> rollout_record.baseline_cohort_release_id
                     OR NOT EXISTS (
                       SELECT 1
                       FROM cohort_rollout_participants participant
                       JOIN cohort_release_exposures prior
                         ON prior.cohort_rollout_id = rollout_record.id
                        AND prior.event_type = 'wave'
                        AND prior.user_id = participant.user_id
                        AND prior.cohort_rollout_wave_id = participant.cohort_rollout_wave_id
                        AND prior.cohort_membership_id = participant.cohort_membership_id
                        AND prior.membership_started_at = participant.membership_started_at
                       JOIN cohort_memberships membership
                         ON membership.id = participant.cohort_membership_id
                        AND membership.cohort_id = participant.cohort_id
                        AND membership.user_id = participant.user_id
                        AND membership.role = 'participant'
                        AND membership.created_at = participant.membership_started_at
                       WHERE participant.cohort_rollout_id = rollout_record.id
                         AND participant.user_id = exposure.user_id
                         AND participant.cohort_rollout_wave_id = exposure.cohort_rollout_wave_id
                         AND participant.cohort_membership_id = exposure.cohort_membership_id
                         AND participant.membership_started_at = exposure.membership_started_at
                     ))
               ) OR EXISTS (
                 SELECT DISTINCT prior.user_id
                 FROM cohort_release_exposures prior
                 JOIN cohort_rollout_participants participant
                   ON participant.cohort_rollout_id = rollout_record.id
                  AND participant.user_id = prior.user_id
                  AND participant.cohort_rollout_wave_id = prior.cohort_rollout_wave_id
                  AND participant.cohort_membership_id = prior.cohort_membership_id
                  AND participant.membership_started_at = prior.membership_started_at
                 JOIN cohort_memberships membership
                   ON membership.id = participant.cohort_membership_id
                  AND membership.cohort_id = participant.cohort_id
                  AND membership.user_id = participant.user_id
                  AND membership.role = 'participant'
                  AND membership.created_at = participant.membership_started_at
                 LEFT JOIN cohort_release_exposures restored
                   ON restored.cohort_rollout_transition_id = transition_record.id
                  AND restored.user_id = prior.user_id
                  AND restored.cohort_rollout_wave_id = prior.cohort_rollout_wave_id
                  AND restored.cohort_membership_id = prior.cohort_membership_id
                  AND restored.membership_started_at = prior.membership_started_at
                  AND restored.event_type = 'rollback'
                  AND restored.cohort_release_id = rollout_record.baseline_cohort_release_id
                 WHERE prior.cohort_rollout_id = rollout_record.id
                   AND prior.event_type = 'wave'
                   AND restored.id IS NULL
               ) THEN
              RAISE EXCEPTION 'runtime rollback must restore the captured baseline'
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
          END IF;
          RETURN;
        END IF;

      IF transition_record.event_type = 'planned' THEN
          expected_before_snapshot := jsonb_build_object(
    SQL
    unless definition&.include?(marker)
      raise "Unable to upgrade rollout execution integrity for runtime v2"
    end

    execute definition.sub(marker, runtime_validation)
  end

  def install_deferred_runtime_evidence_integrity
    execute <<~SQL
      CREATE OR REPLACE FUNCTION mark_cohort_runtime_transition_pending()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        validation_key text;
      BEGIN
        IF NEW.cohort_rollout_transition_id IS NOT NULL THEN
          validation_key := format(
            'household_cfo.runtime_transition_%s',
            NEW.cohort_rollout_transition_id
          );
          PERFORM set_config(validation_key, 'pending', true);
        END IF;
        RETURN NEW;
      END;
      $$
    SQL
    %w[cohort_release_exposures cohort_release_activation_events].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_transition_pending
        BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION mark_cohort_runtime_transition_pending()
      SQL
    end
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prepare_cohort_release_activation_event()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        current_release_id bigint;
        rollout_record cohort_rollouts%ROWTYPE;
        transition_record cohort_rollout_transitions%ROWTYPE;
      BEGIN
        SELECT active_cohort_release_id INTO current_release_id
        FROM cohorts
        WHERE id = NEW.cohort_id AND coach_workspace_id = NEW.coach_workspace_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'release activation cohort does not exist in the claimed workspace'
            USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF current_release_id IS DISTINCT FROM NEW.from_cohort_release_id THEN
          RAISE EXCEPTION 'release activation evidence must start from the current cohort release'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.event_type = 'backfill' THEN
          IF NEW.from_cohort_release_id IS NOT NULL THEN
            RAISE EXCEPTION 'runtime backfill may only activate a cohort without an active release'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF NEW.event_type = 'rollout_completed' THEN
          SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = NEW.cohort_rollout_id;
          SELECT * INTO transition_record FROM cohort_rollout_transitions WHERE id = NEW.cohort_rollout_transition_id;
          IF rollout_record.id IS NULL
             OR transition_record.id IS NULL
             OR transition_record.cohort_rollout_id <> rollout_record.id
             OR transition_record.event_type <> 'completed'
             OR rollout_record.baseline_cohort_release_id IS DISTINCT FROM NEW.from_cohort_release_id
             OR rollout_record.target_cohort_release_id IS DISTINCT FROM NEW.to_cohort_release_id
             OR transition_record.actor_user_id IS DISTINCT FROM NEW.actor_user_id
             OR transition_record.actor_role_snapshot IS DISTINCT FROM NEW.actor_role_snapshot
             OR transition_record.occurred_at IS DISTINCT FROM NEW.occurred_at THEN
            RAISE EXCEPTION 'rollout activation evidence must match its completed transition and release change'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;

        NEW.database_transaction_id := txid_current();
        RETURN NEW;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE TRIGGER cohort_release_activation_events_prepare
      BEFORE INSERT ON cohort_release_activation_events
      FOR EACH ROW EXECUTE FUNCTION prepare_cohort_release_activation_event()
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_cohort_active_release_change_integrity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        matching_events integer;
      BEGIN
        IF OLD.active_cohort_release_id IS NOT DISTINCT FROM NEW.active_cohort_release_id THEN
          RETURN NULL;
        END IF;

        SELECT count(*) INTO matching_events
        FROM cohort_release_activation_events event
        WHERE event.cohort_id = NEW.id
          AND event.coach_workspace_id = NEW.coach_workspace_id
          AND event.from_cohort_release_id IS NOT DISTINCT FROM OLD.active_cohort_release_id
          AND event.to_cohort_release_id = NEW.active_cohort_release_id
          AND event.database_transaction_id = txid_current();

        IF matching_events <> 1 THEN
          RAISE EXCEPTION 'active cohort release changes require exactly one matching activation event in the same transaction'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NULL;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE CONSTRAINT TRIGGER cohort_active_release_change_integrity_deferred
      AFTER UPDATE OF active_cohort_release_id ON cohorts
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_cohort_active_release_change_integrity()
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_cohort_runtime_evidence_integrity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        active_release_id bigint;
        validation_key text;
      BEGIN
        IF TG_TABLE_NAME = 'cohort_release_activation_events' THEN
          SELECT cohorts.active_cohort_release_id INTO active_release_id
          FROM cohorts WHERE cohorts.id = NEW.cohort_id;
          IF active_release_id IS DISTINCT FROM NEW.to_cohort_release_id
             OR NEW.database_transaction_id <> txid_current() THEN
            RAISE EXCEPTION 'release activation evidence must match the resulting cohort pointer in the same transaction'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;
        IF NEW.cohort_rollout_transition_id IS NOT NULL THEN
          validation_key := format(
            'household_cfo.runtime_transition_%s',
            NEW.cohort_rollout_transition_id
          );
          IF current_setting(validation_key, true) IS DISTINCT FROM txid_current()::text THEN
            PERFORM validate_cohort_rollout_transition_integrity(NEW.cohort_rollout_transition_id);
            PERFORM set_config(validation_key, txid_current()::text, true);
          END IF;
        END IF;
        RETURN NULL;
      END;
      $$
    SQL
    %w[cohort_release_exposures cohort_release_activation_events].each do |table|
      execute <<~SQL
        CREATE CONSTRAINT TRIGGER #{table}_integrity_deferred
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION check_cohort_runtime_evidence_integrity()
      SQL
    end
  end
end
