# frozen_string_literal: true

class ExtendCoachOperationExecutionsForRollouts < ActiveRecord::Migration[8.1]
  RELEASE_OPERATION_KEYS = %w[cohort.release.seal cohort.release.restore].freeze
  ROLLOUT_OPERATION_KEYS = %w[
    cohort.rollout.plan
    cohort.rollout.advance
    cohort.rollout.pause
    cohort.rollout.resume
    cohort.rollout.cancel
    cohort.rollout.rollback
  ].freeze

  def up
    add_reference :coach_operation_executions, :cohort_rollout_transition,
      null: true,
      foreign_key: { on_delete: :restrict },
      index: { unique: true, name: "idx_coach_operations_rollout_transition_unique" }

    change_column_null :coach_operation_executions, :cohort_release_id, true

    remove_check_constraint :coach_operation_executions, name: "coach_operations_key_valid"
    all_keys = (RELEASE_OPERATION_KEYS + ROLLOUT_OPERATION_KEYS).map { |key| connection.quote(key) }.join(", ")
    add_check_constraint :coach_operation_executions,
      "operation_key IN (#{all_keys})",
      name: "coach_operations_key_valid"
    add_check_constraint :coach_operation_executions,
      "num_nonnulls(cohort_release_id, cohort_rollout_transition_id) = 1",
      name: "coach_operations_exactly_one_result"
    add_check_constraint :coach_operation_executions, <<~SQL.squish,
      (operation_key IN ('cohort.release.seal', 'cohort.release.restore') AND
        cohort_release_id IS NOT NULL AND cohort_rollout_transition_id IS NULL) OR
      (operation_key IN ('cohort.rollout.plan', 'cohort.rollout.advance', 'cohort.rollout.pause',
        'cohort.rollout.resume', 'cohort.rollout.cancel', 'cohort.rollout.rollback') AND
        cohort_release_id IS NULL AND cohort_rollout_transition_id IS NOT NULL)
    SQL
      name: "coach_operations_result_matches_key"

    execute <<~SQL
      ALTER TABLE coach_operation_executions
      ADD CONSTRAINT fk_coach_operations_rollout_transition
      FOREIGN KEY (cohort_rollout_transition_id, cohort_id, coach_workspace_id)
      REFERENCES cohort_rollout_transitions (id, cohort_id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE coach_operation_executions
      ADD CONSTRAINT fk_coach_operations_rollout_transition_actor
      FOREIGN KEY (cohort_rollout_transition_id, actor_user_id, actor_role_snapshot)
      REFERENCES cohort_rollout_transitions (id, actor_user_id, actor_role_snapshot)
      ON DELETE RESTRICT
    SQL

    add_deferred_rollout_integrity!
  end

  def down
    execute "LOCK TABLE coach_operation_executions IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM coach_operation_executions WHERE cohort_rollout_transition_id IS NOT NULL LIMIT 1").present?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove immutable rollout operation evidence after rollout transitions have completed"
    end

    remove_deferred_rollout_integrity!

    remove_foreign_key :coach_operation_executions, name: "fk_coach_operations_rollout_transition_actor"
    remove_foreign_key :coach_operation_executions, name: "fk_coach_operations_rollout_transition"
    remove_check_constraint :coach_operation_executions, name: "coach_operations_result_matches_key"
    remove_check_constraint :coach_operation_executions, name: "coach_operations_exactly_one_result"
    remove_check_constraint :coach_operation_executions, name: "coach_operations_key_valid"
    add_check_constraint :coach_operation_executions,
      "operation_key IN ('cohort.release.seal', 'cohort.release.restore')",
      name: "coach_operations_key_valid"
    change_column_null :coach_operation_executions, :cohort_release_id, false
    remove_reference :coach_operation_executions, :cohort_rollout_transition,
      foreign_key: true,
      index: { name: "idx_coach_operations_rollout_transition_unique" }
  end


  private

  def add_deferred_rollout_integrity!
    # PostgreSQL validates exact relational JSON evidence and each immutable append
    # independently. SHA-256 recomputation remains in CoachOperationExecution because
    # pgcrypto is not a guaranteed production extension; digest shape is still checked.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION validate_cohort_rollout_plan_integrity(checked_rollout_id bigint)
      RETURNS void
      LANGUAGE plpgsql
      AS $$
      DECLARE
        rollout_record cohort_rollouts%ROWTYPE;
        maximum_wave_position integer;
        wave_count integer;
      BEGIN
        SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = checked_rollout_id;
        IF NOT FOUND THEN
          RETURN;
        END IF;
        IF rollout_record.target_cohort_release_id IS DISTINCT FROM (
          SELECT release.id
          FROM cohort_releases release
          WHERE release.cohort_id = rollout_record.cohort_id
            AND release.coach_workspace_id = rollout_record.coach_workspace_id
          ORDER BY release.release_number DESC
          LIMIT 1
        ) THEN
          RAISE EXCEPTION 'planned rollout must target the latest sealed release'
            USING ERRCODE = 'check_violation',
              CONSTRAINT = 'cohort_rollout_target_is_latest_release';
        END IF;
        IF ARRAY(
          SELECT participant.user_id
          FROM cohort_rollout_participants participant
          WHERE participant.cohort_rollout_id = checked_rollout_id
          ORDER BY participant.user_id
        ) IS DISTINCT FROM ARRAY(
          SELECT membership.user_id
          FROM cohort_memberships membership
          WHERE membership.cohort_id = rollout_record.cohort_id
            AND membership.role = 'participant'
          ORDER BY membership.user_id
        ) THEN
          RAISE EXCEPTION 'planned rollout roster must exactly match current cohort participants'
            USING ERRCODE = 'check_violation',
              CONSTRAINT = 'cohort_rollout_roster_matches_current_participants';
        END IF;
        SELECT COUNT(*), MAX(position) INTO wave_count, maximum_wave_position
        FROM cohort_rollout_waves
        WHERE cohort_rollout_id = checked_rollout_id;
        IF wave_count < 1 OR wave_count > 25 OR maximum_wave_position IS DISTINCT FROM wave_count
           OR EXISTS (
             SELECT 1
             FROM cohort_rollout_waves wave
             WHERE wave.cohort_rollout_id = checked_rollout_id
               AND NOT EXISTS (
                 SELECT 1
                 FROM cohort_rollout_participants participant
                 WHERE participant.cohort_rollout_wave_id = wave.id
               )
           ) THEN
          RAISE EXCEPTION 'rollout waves must be contiguous, bounded, and nonempty'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END;
      $$
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION validate_cohort_rollout_transition_integrity(checked_transition_id bigint)
      RETURNS void
      LANGUAGE plpgsql
      AS $$
      DECLARE
        rollout_record cohort_rollouts%ROWTYPE;
        transition_record cohort_rollout_transitions%ROWTYPE;
        previous_transition cohort_rollout_transitions%ROWTYPE;
        execution_record coach_operation_executions%ROWTYPE;
        previous_transition_id bigint := NULL;
        maximum_wave_position integer;
        execution_count integer;
        expected_operation_key varchar;
        planned_waves jsonb;
        expected_input jsonb;
        expected_before_snapshot jsonb;
        expected_predicted_snapshot jsonb;
        expected_after_snapshot jsonb;
      BEGIN
        SELECT * INTO transition_record
        FROM cohort_rollout_transitions
        WHERE id = checked_transition_id;
        IF NOT FOUND THEN
          RETURN;
        END IF;
        SELECT * INTO rollout_record
        FROM cohort_rollouts
        WHERE id = transition_record.cohort_rollout_id;

        SELECT * INTO previous_transition
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = transition_record.cohort_rollout_id
          AND id < transition_record.id
        ORDER BY id DESC
        LIMIT 1;
        IF FOUND THEN
          previous_transition_id := previous_transition.id;
          IF transition_record.event_type = 'planned'
             OR transition_record.from_status IS DISTINCT FROM previous_transition.to_status
             OR transition_record.from_wave_position IS DISTINCT FROM previous_transition.to_wave_position THEN
            RAISE EXCEPTION 'rollout transition does not append one contiguous state tail'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSIF transition_record.event_type <> 'planned' THEN
          RAISE EXCEPTION 'the first rollout transition must be planned'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        SELECT MAX(position) INTO maximum_wave_position
        FROM cohort_rollout_waves
        WHERE cohort_rollout_id = transition_record.cohort_rollout_id;
        IF transition_record.to_wave_position > COALESCE(maximum_wave_position, 0) THEN
          RAISE EXCEPTION 'rollout transition references a wave outside the immutable plan'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.event_type = 'completed'
           AND transition_record.to_wave_position IS DISTINCT FROM maximum_wave_position THEN
          RAISE EXCEPTION 'a rollout can complete only after its final wave'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.event_type = 'rolled_back' AND NOT EXISTS (
          SELECT 1
          FROM cohort_releases rollback_release
          JOIN cohort_releases target_release
            ON target_release.id = rollout_record.target_cohort_release_id
          WHERE rollback_release.id = transition_record.rollback_cohort_release_id
            AND rollback_release.release_number < target_release.release_number
        ) THEN
          RAISE EXCEPTION 'rollback release must predate the rollout target release'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF transition_record.event_type = 'planned'
           AND (transition_record.actor_user_id IS DISTINCT FROM rollout_record.planned_by_user_id
             OR transition_record.actor_role_snapshot IS DISTINCT FROM rollout_record.planned_by_role_snapshot) THEN
          RAISE EXCEPTION 'planned rollout attribution must match the immutable planner'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        SELECT COUNT(*) INTO execution_count
        FROM coach_operation_executions
        WHERE cohort_rollout_transition_id = transition_record.id;
        IF execution_count <> 1 THEN
          RAISE EXCEPTION 'every rollout transition must have exactly one coach operation execution'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT * INTO execution_record
        FROM coach_operation_executions
        WHERE cohort_rollout_transition_id = transition_record.id;

        expected_operation_key := CASE transition_record.event_type
          WHEN 'planned' THEN 'cohort.rollout.plan'
          WHEN 'activated' THEN 'cohort.rollout.advance'
          WHEN 'advanced' THEN 'cohort.rollout.advance'
          WHEN 'completed' THEN 'cohort.rollout.advance'
          WHEN 'paused' THEN 'cohort.rollout.pause'
          WHEN 'resumed' THEN 'cohort.rollout.resume'
          WHEN 'cancelled' THEN 'cohort.rollout.cancel'
          WHEN 'rolled_back' THEN 'cohort.rollout.rollback'
        END;
        IF execution_record.operation_key IS DISTINCT FROM expected_operation_key
           OR execution_record.actor_user_id IS DISTINCT FROM transition_record.actor_user_id
           OR execution_record.actor_role_snapshot IS DISTINCT FROM transition_record.actor_role_snapshot
           OR execution_record.completed_at IS DISTINCT FROM transition_record.occurred_at THEN
          RAISE EXCEPTION 'rollout operation identity does not match its transition'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF transition_record.event_type = 'planned' THEN
          SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
              'name', wave.name,
              'user_ids', COALESCE((
                SELECT jsonb_agg(participant.user_id ORDER BY participant.user_id)
                FROM cohort_rollout_participants participant
                WHERE participant.cohort_rollout_wave_id = wave.id
              ), '[]'::jsonb)
            ) ORDER BY wave.position
          ), '[]'::jsonb)
          INTO planned_waves
          FROM cohort_rollout_waves wave
          WHERE wave.cohort_rollout_id = transition_record.cohort_rollout_id;
          expected_input := jsonb_build_object(
            'target_release_id', rollout_record.target_cohort_release_id,
            'expected_latest_release_id', rollout_record.target_cohort_release_id,
            'expected_roster_digest', execution_record.normalized_input->>'expected_roster_digest',
            'waves', planned_waves
          );
          IF execution_record.normalized_input IS DISTINCT FROM expected_input
             OR (execution_record.normalized_input->>'expected_roster_digest') !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'planned rollout input does not match the immutable plan'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSE
          expected_input := jsonb_build_object(
            'rollout_id', transition_record.cohort_rollout_id,
            'expected_status', transition_record.from_status,
            'expected_current_wave_position', transition_record.from_wave_position,
            'expected_latest_transition_id', previous_transition_id
          );
          IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
            expected_input := expected_input || jsonb_build_object('readiness_digest', transition_record.readiness_digest);
          ELSIF transition_record.event_type = 'rolled_back' THEN
            expected_input := expected_input || jsonb_build_object(
              'rollback_release_id', transition_record.rollback_cohort_release_id
            );
          END IF;
          IF execution_record.normalized_input IS DISTINCT FROM expected_input THEN
            RAISE EXCEPTION 'rollout transition input does not match its immutable CAS evidence'
              USING ERRCODE = 'integrity_constraint_violation',
                DETAIL = format(
                  'transition_id=%s expected=%s actual=%s',
                  transition_record.id,
                  expected_input,
                  execution_record.normalized_input
                );
          END IF;
        END IF;

        IF transition_record.event_type = 'planned' THEN
          expected_before_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v1',
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
            'participant_runtime_changed', false
          );
          expected_predicted_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v1',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', NULL,
            'rollout_id_pending', true,
            'status', transition_record.to_status,
            'current_wave_position', transition_record.to_wave_position,
            'latest_transition_id', NULL,
            'latest_transition_id_pending', true,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', transition_record.rollback_cohort_release_id,
            'participant_runtime_changed', false
          );
        ELSE
          expected_before_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v1',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', transition_record.cohort_rollout_id,
            'status', transition_record.from_status,
            'current_wave_position', transition_record.from_wave_position,
            'latest_transition_id', previous_transition_id,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', NULL,
            'participant_runtime_changed', false
          );
          IF transition_record.event_type IN ('activated', 'advanced', 'completed') THEN
            expected_before_snapshot := expected_before_snapshot ||
              jsonb_build_object('readiness_digest', transition_record.readiness_digest);
          END IF;
          expected_predicted_snapshot := jsonb_build_object(
            'schema', 'cohort_rollout_state_v1',
            'cohort_id', rollout_record.cohort_id,
            'coach_workspace_id', rollout_record.coach_workspace_id,
            'rollout_id', transition_record.cohort_rollout_id,
            'status', transition_record.to_status,
            'current_wave_position', transition_record.to_wave_position,
            'latest_transition_id', NULL,
            'latest_transition_id_pending', true,
            'target_release_id', rollout_record.target_cohort_release_id,
            'rollback_release_id', transition_record.rollback_cohort_release_id,
            'participant_runtime_changed', false
          );
        END IF;

        expected_after_snapshot := jsonb_build_object(
          'schema', 'cohort_rollout_state_v1',
          'cohort_id', rollout_record.cohort_id,
          'coach_workspace_id', rollout_record.coach_workspace_id,
          'rollout_id', transition_record.cohort_rollout_id,
          'status', transition_record.to_status,
          'current_wave_position', transition_record.to_wave_position,
          'latest_transition_id', transition_record.id,
          'target_release_id', rollout_record.target_cohort_release_id,
          'rollback_release_id', transition_record.rollback_cohort_release_id,
          'participant_runtime_changed', false
        );
        IF execution_record.before_snapshot IS DISTINCT FROM expected_before_snapshot
           OR execution_record.predicted_after_snapshot IS DISTINCT FROM expected_predicted_snapshot
           OR execution_record.after_snapshot IS DISTINCT FROM expected_after_snapshot THEN
          RAISE EXCEPTION 'rollout operation snapshots do not match exact relational evidence'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END;
      $$
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION validate_cohort_rollout_latest_integrity(checked_rollout_id bigint)
      RETURNS void
      LANGUAGE plpgsql
      AS $$
      DECLARE
        rollout_record cohort_rollouts%ROWTYPE;
        latest_transition cohort_rollout_transitions%ROWTYPE;
        previous_transition cohort_rollout_transitions%ROWTYPE;
        planned_occurred_at timestamp := NULL;
        activated_occurred_at timestamp := NULL;
        expected_paused_at timestamp := NULL;
      BEGIN
        SELECT * INTO rollout_record FROM cohort_rollouts WHERE id = checked_rollout_id;
        IF NOT FOUND THEN
          RETURN;
        END IF;
        SELECT * INTO latest_transition
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = checked_rollout_id
        ORDER BY id DESC
        LIMIT 1;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'every rollout must have transition history'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF rollout_record.status IS DISTINCT FROM latest_transition.to_status
           OR rollout_record.current_wave_position IS DISTINCT FROM latest_transition.to_wave_position
           OR rollout_record.rollback_cohort_release_id IS DISTINCT FROM latest_transition.rollback_cohort_release_id THEN
          RAISE EXCEPTION 'rollout state must match its latest transition'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        SELECT occurred_at INTO planned_occurred_at
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = checked_rollout_id AND event_type = 'planned'
        ORDER BY id
        LIMIT 1;
        SELECT occurred_at INTO activated_occurred_at
        FROM cohort_rollout_transitions
        WHERE cohort_rollout_id = checked_rollout_id AND event_type = 'activated'
        ORDER BY id
        LIMIT 1;
        IF rollout_record.status = 'paused' THEN
          expected_paused_at := latest_transition.occurred_at;
        ELSIF rollout_record.status = 'rolled_back' AND latest_transition.from_status = 'paused' THEN
          SELECT * INTO previous_transition
          FROM cohort_rollout_transitions
          WHERE cohort_rollout_id = checked_rollout_id AND id < latest_transition.id
          ORDER BY id DESC
          LIMIT 1;
          expected_paused_at := previous_transition.occurred_at;
        END IF;

        IF rollout_record.planned_at IS DISTINCT FROM planned_occurred_at
           OR rollout_record.activated_at IS DISTINCT FROM activated_occurred_at
           OR rollout_record.paused_at IS DISTINCT FROM expected_paused_at THEN
          RAISE EXCEPTION 'rollout lifecycle timestamps must match transition history'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF (rollout_record.status = 'completed' AND rollout_record.completed_at IS DISTINCT FROM latest_transition.occurred_at)
           OR (rollout_record.status <> 'completed' AND rollout_record.completed_at IS NOT NULL)
           OR (rollout_record.status = 'cancelled' AND rollout_record.cancelled_at IS DISTINCT FROM latest_transition.occurred_at)
           OR (rollout_record.status <> 'cancelled' AND rollout_record.cancelled_at IS NOT NULL)
           OR (rollout_record.status = 'rolled_back' AND rollout_record.rolled_back_at IS DISTINCT FROM latest_transition.occurred_at)
           OR (rollout_record.status <> 'rolled_back' AND rollout_record.rolled_back_at IS NOT NULL) THEN
          RAISE EXCEPTION 'rollout terminal timestamps must match the terminal transition'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END;
      $$
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_cohort_rollout_row_integrity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          PERFORM validate_cohort_rollout_plan_integrity(NEW.id);
        END IF;
        PERFORM validate_cohort_rollout_latest_integrity(COALESCE(NEW.id, OLD.id));
        RETURN NULL;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_cohort_rollout_transition_integrity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM validate_cohort_rollout_transition_integrity(COALESCE(NEW.id, OLD.id));
        PERFORM validate_cohort_rollout_latest_integrity(COALESCE(NEW.cohort_rollout_id, OLD.cohort_rollout_id));
        RETURN NULL;
      END;
      $$
    SQL
    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_cohort_rollout_execution_integrity()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF COALESCE(NEW.cohort_rollout_transition_id, OLD.cohort_rollout_transition_id) IS NULL THEN
          RETURN NULL;
        END IF;
        PERFORM validate_cohort_rollout_transition_integrity(
          COALESCE(NEW.cohort_rollout_transition_id, OLD.cohort_rollout_transition_id)
        );
        RETURN NULL;
      END;
      $$
    SQL

    execute <<~SQL
      CREATE CONSTRAINT TRIGGER cohort_rollouts_integrity_deferred
      AFTER INSERT OR UPDATE OR DELETE ON cohort_rollouts
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_row_integrity()
    SQL
    execute <<~SQL
      CREATE CONSTRAINT TRIGGER cohort_rollout_transitions_integrity_deferred
      AFTER INSERT OR UPDATE OR DELETE ON cohort_rollout_transitions
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_transition_integrity()
    SQL
    execute <<~SQL
      CREATE CONSTRAINT TRIGGER coach_operation_rollout_integrity_deferred
      AFTER INSERT OR UPDATE OR DELETE ON coach_operation_executions
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_cohort_rollout_execution_integrity()
    SQL
  end

  def remove_deferred_rollout_integrity!
    execute "DROP TRIGGER IF EXISTS coach_operation_rollout_integrity_deferred ON coach_operation_executions"
    execute "DROP TRIGGER IF EXISTS cohort_rollout_transitions_integrity_deferred ON cohort_rollout_transitions"
    execute "DROP TRIGGER IF EXISTS cohort_rollouts_integrity_deferred ON cohort_rollouts"
    execute "DROP FUNCTION IF EXISTS check_cohort_rollout_execution_integrity()"
    execute "DROP FUNCTION IF EXISTS check_cohort_rollout_transition_integrity()"
    execute "DROP FUNCTION IF EXISTS check_cohort_rollout_row_integrity()"
    execute "DROP FUNCTION IF EXISTS validate_cohort_rollout_latest_integrity(bigint)"
    execute "DROP FUNCTION IF EXISTS validate_cohort_rollout_transition_integrity(bigint)"
    execute "DROP FUNCTION IF EXISTS validate_cohort_rollout_plan_integrity(bigint)"
  end
end
