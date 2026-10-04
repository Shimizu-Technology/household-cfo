# frozen_string_literal: true

class EnableGovernedInitialCohortLaunch < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # Commit the brief constraint/function replacement before scanning history.
    # NOT VALID still checks new writes while validation uses a weaker lock.
    connection.transaction do
      remove_check_constraint :cohort_release_activation_events, name: "release_activation_events_type_valid"
      remove_check_constraint :cohort_release_activation_events, name: "release_activation_events_shape"
      add_check_constraint :cohort_release_activation_events,
        "event_type IN ('backfill', 'initial_launch', 'rollout_completed')", name: "release_activation_events_type_valid", validate: false
      add_check_constraint :cohort_release_activation_events,
        <<~SQL.squish, name: "release_activation_events_shape", validate: false
          (event_type = 'backfill' AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL
            AND actor_user_id IS NULL AND actor_role_snapshot IS NULL)
          OR
          (event_type = 'initial_launch' AND from_cohort_release_id IS NULL
            AND cohort_rollout_id IS NULL AND cohort_rollout_transition_id IS NULL
            AND actor_user_id IS NOT NULL AND actor_role_snapshot IS NOT NULL
            AND actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer'))
          OR
          (event_type = 'rollout_completed' AND cohort_rollout_id IS NOT NULL AND cohort_rollout_transition_id IS NOT NULL
            AND actor_user_id IS NOT NULL AND actor_role_snapshot IS NOT NULL
            AND actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer'))
        SQL
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

          IF NEW.event_type IN ('backfill', 'initial_launch') THEN
            IF NEW.from_cohort_release_id IS NOT NULL THEN
              RAISE EXCEPTION 'initial activation requires a cohort without an active release'
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
    end
    validate_check_constraint :cohort_release_activation_events, name: "release_activation_events_type_valid"
    validate_check_constraint :cohort_release_activation_events, name: "release_activation_events_shape"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Initial cohort launches are append-only participant runtime audit history."
  end
end
