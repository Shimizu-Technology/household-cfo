# frozen_string_literal: true

# Rails' PostgreSQL schema dumper does not preserve functions or triggers. Keep
# the database-level immutability guarantee in schema.rb so a fresh schema load
# enforces the same contract as the migration path.
module CohortReleaseSchemaDumper
  private

  def trailer(stream)
    dump_cohort_release_immutability(stream) if @connection.table_exists?("cohort_releases")
    dump_coach_operation_immutability(stream) if @connection.table_exists?("coach_operation_executions")
    dump_cohort_rollout_identity_protection(stream) if @connection.table_exists?("cohort_rollouts")
    dump_cohort_rollout_lifecycle_guards(stream) if @connection.table_exists?("cohort_rollouts")
    dump_cohort_rollout_wave_immutability(stream) if @connection.table_exists?("cohort_rollout_waves")
    dump_cohort_rollout_participant_immutability(stream) if @connection.table_exists?("cohort_rollout_participants")
    dump_cohort_rollout_participant_limit(stream) if @connection.table_exists?("cohort_rollout_participants")
    dump_cohort_rollout_plan_append_guards(stream) if @connection.table_exists?("cohort_rollout_participants")
    dump_cohort_rollout_transition_immutability(stream) if @connection.table_exists?("cohort_rollout_transitions")
    dump_cohort_rollout_transition_append_guard(stream) if @connection.table_exists?("cohort_rollout_transitions")
    dump_deferred_cohort_rollout_integrity(stream) if @connection.table_exists?("cohort_rollout_transitions") &&
      @connection.column_exists?("coach_operation_executions", "cohort_rollout_transition_id")
    dump_cohort_runtime_guards(stream) if @connection.table_exists?("cohort_release_exposures")
    dump_workspace_brand_evidence_guards(stream) if @connection.table_exists?("workspace_brand_versions")
    dump_workspace_membership_event_guards(stream) if @connection.table_exists?("coach_workspace_membership_events")
    super
  end

  def dump_cohort_release_immutability(stream)
    stream.puts <<~'RUBY'
        execute <<~SQL
          CREATE OR REPLACE FUNCTION prevent_cohort_release_mutation()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'cohort releases are immutable'
              USING ERRCODE = 'integrity_constraint_violation';
          END;
          $$
        SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS cohort_releases_immutable ON cohort_releases;
          CREATE TRIGGER cohort_releases_immutable
          BEFORE UPDATE OR DELETE ON cohort_releases
          FOR EACH ROW
          EXECUTE FUNCTION prevent_cohort_release_mutation()
        SQL
    RUBY
  end

  def dump_coach_operation_immutability(stream)
    stream.puts <<~'RUBY'
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
          DROP TRIGGER IF EXISTS coach_operation_executions_immutable ON coach_operation_executions;
          CREATE TRIGGER coach_operation_executions_immutable
          BEFORE UPDATE OR DELETE ON coach_operation_executions
          FOR EACH ROW
          EXECUTE FUNCTION prevent_coach_operation_execution_mutation()
        SQL
    RUBY
  end

  def dump_cohort_rollout_identity_protection(stream)
    stream.puts <<~'RUBY'
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
                OLD.baseline_cohort_release_id, OLD.planned_by_user_id, OLD.planned_by_role_snapshot, OLD.planned_at, OLD.created_at)
               IS DISTINCT FROM
               (NEW.id, NEW.coach_workspace_id, NEW.cohort_id, NEW.target_cohort_release_id,
                NEW.baseline_cohort_release_id, NEW.planned_by_user_id, NEW.planned_by_role_snapshot, NEW.planned_at, NEW.created_at) THEN
              RAISE EXCEPTION 'cohort rollout plan identity is immutable'
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
            RETURN NEW;
          END;
          $$
        SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS cohort_rollouts_protect_identity ON cohort_rollouts;
          CREATE TRIGGER cohort_rollouts_protect_identity
          BEFORE UPDATE OR DELETE ON cohort_rollouts
          FOR EACH ROW
          EXECUTE FUNCTION protect_cohort_rollout_identity()
        SQL
    RUBY
  end

  def dump_cohort_rollout_lifecycle_guards(stream)
    stream.puts <<~'RUBY'
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
          DROP TRIGGER IF EXISTS cohorts_open_rollout_lifecycle_guard ON cohorts;
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
          DROP TRIGGER IF EXISTS cohort_rollouts_cohort_lifecycle_guard ON cohort_rollouts;
          CREATE TRIGGER cohort_rollouts_cohort_lifecycle_guard
          BEFORE INSERT ON cohort_rollouts
          FOR EACH ROW
          EXECUTE FUNCTION enforce_cohort_rollout_cohort_lifecycle()
        SQL
    RUBY
  end

  def dump_cohort_rollout_wave_immutability(stream)
    dump_cohort_rollout_immutability(
      stream,
      table: "cohort_rollout_waves",
      function: "prevent_cohort_rollout_wave_mutation",
      trigger: "cohort_rollout_waves_immutable",
      message: "cohort rollout waves are immutable"
    )
  end

  def dump_cohort_rollout_participant_immutability(stream)
    dump_cohort_rollout_immutability(
      stream,
      table: "cohort_rollout_participants",
      function: "prevent_cohort_rollout_participant_mutation",
      trigger: "cohort_rollout_participants_immutable",
      message: "cohort rollout participants are immutable"
    )
  end

  def dump_cohort_rollout_transition_immutability(stream)
    dump_cohort_rollout_immutability(
      stream,
      table: "cohort_rollout_transitions",
      function: "prevent_cohort_rollout_transition_mutation",
      trigger: "cohort_rollout_transitions_immutable",
      message: "cohort rollout transitions are immutable"
    )
  end

  def dump_cohort_rollout_transition_append_guard(stream)
    stream.puts <<~'RUBY'
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
          DROP TRIGGER IF EXISTS cohort_rollout_transitions_enforce_append ON cohort_rollout_transitions;
          CREATE TRIGGER cohort_rollout_transitions_enforce_append
          BEFORE INSERT ON cohort_rollout_transitions
          FOR EACH ROW
          EXECUTE FUNCTION enforce_cohort_rollout_transition_append()
        SQL
    RUBY
  end

  def dump_cohort_rollout_participant_limit(stream)
    stream.puts <<~'RUBY'
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
          DROP TRIGGER IF EXISTS cohort_rollout_participants_limit ON cohort_rollout_participants;
          CREATE TRIGGER cohort_rollout_participants_limit
          BEFORE INSERT ON cohort_rollout_participants
          FOR EACH ROW
          EXECUTE FUNCTION enforce_cohort_rollout_participant_limit()
        SQL
    RUBY
  end

  def dump_cohort_rollout_plan_append_guards(stream)
    stream.puts <<~'RUBY'
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
        execute <<~SQL
          DROP TRIGGER IF EXISTS cohort_rollout_waves_prevent_append ON cohort_rollout_waves;
          CREATE TRIGGER cohort_rollout_waves_prevent_append
          BEFORE INSERT ON cohort_rollout_waves
          FOR EACH ROW
          EXECUTE FUNCTION prevent_cohort_rollout_plan_append()
        SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS cohort_rollout_participants_prevent_append ON cohort_rollout_participants;
          CREATE TRIGGER cohort_rollout_participants_prevent_append
          BEFORE INSERT ON cohort_rollout_participants
          FOR EACH ROW
          EXECUTE FUNCTION prevent_cohort_rollout_plan_append()
        SQL
    RUBY
  end

  def dump_cohort_rollout_immutability(stream, table:, function:, trigger:, message:)
    stream.puts <<~RUBY
        execute <<~SQL
          CREATE OR REPLACE FUNCTION #{function}()
          RETURNS trigger
          LANGUAGE plpgsql
          AS \$\$
          BEGIN
            RAISE EXCEPTION '#{message}'
              USING ERRCODE = 'integrity_constraint_violation';
          END;
          \$\$
        SQL
        execute <<~SQL
          DROP TRIGGER IF EXISTS #{trigger} ON #{table};
          CREATE TRIGGER #{trigger}
          BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW
          EXECUTE FUNCTION #{function}()
        SQL
    RUBY
  end

  def dump_deferred_cohort_rollout_integrity(stream)
    %w[
      validate_cohort_rollout_plan_integrity(bigint)
      validate_cohort_rollout_transition_integrity(bigint)
      validate_cohort_rollout_latest_integrity(bigint)
      check_cohort_rollout_row_integrity()
      check_cohort_rollout_transition_integrity()
      check_cohort_rollout_execution_integrity()
    ].each do |signature|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(signature)}))
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end

    %w[
      cohort_rollouts_integrity_deferred
      cohort_rollout_transitions_integrity_deferred
      coach_operation_rollout_integrity_deferred
    ].each do |trigger|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_triggerdef(oid) || ';'
        FROM pg_trigger
        WHERE tgname = #{@connection.quote(trigger)} AND NOT tgisinternal
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end
  end

  def dump_rollout_database_definition(stream, definition)
    stream.puts "  execute <<~'SQL'"
    definition.each_line do |line|
      line = line.rstrip
      stream.puts(line.empty? ? "" : "    #{line}")
    end
    stream.puts "  SQL"
  end

  def dump_cohort_runtime_guards(stream)
    %w[
      prevent_cohort_runtime_evidence_mutation()
      enforce_cohort_runtime_scope()
      enforce_cohort_release_exposure_membership_epoch()
      enforce_cohort_rollout_participant_membership_epoch()
      mark_cohort_runtime_transition_pending()
      prepare_cohort_release_activation_event()
      check_cohort_active_release_change_integrity()
      check_cohort_runtime_evidence_integrity()
    ].each do |signature|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(signature)}))
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end

    %w[
      cohort_release_exposures_immutable
      cohort_release_activation_events_immutable
      cohort_runtime_scope_guard
      cohort_release_exposures_membership_epoch_guard
      cohort_rollout_participants_membership_epoch_guard
      cohort_release_exposures_transition_pending
      cohort_release_activation_events_transition_pending
      cohort_release_activation_events_prepare
      cohort_active_release_change_integrity_deferred
      cohort_release_exposures_integrity_deferred
      cohort_release_activation_events_integrity_deferred
    ].each do |trigger|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_triggerdef(oid) || ';'
        FROM pg_trigger
        WHERE tgname = #{@connection.quote(trigger)} AND NOT tgisinternal
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end
  end

  def dump_workspace_membership_event_guards(stream)
    definition = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('prevent_workspace_membership_event_mutation()'))")
    dump_rollout_database_definition(stream, definition) if definition.present?
    definition = @connection.select_value(<<~SQL.squish)
      SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger
      WHERE tgname = 'workspace_membership_events_immutable' AND NOT tgisinternal
    SQL
    dump_rollout_database_definition(stream, definition) if definition.present?
  end

  def dump_workspace_brand_evidence_guards(stream)
    %w[
      prevent_workspace_brand_evidence_mutation()
      prevent_verified_workspace_domain_identity_change()
    ].each do |function|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(function)}))
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end

    %w[
      workspace_brand_versions_immutable
      workspace_brand_publication_events_immutable
      coach_workspace_domain_events_immutable
      coach_workspace_domains_verified_identity
    ].each do |trigger|
      definition = @connection.select_value(<<~SQL.squish)
        SELECT pg_get_triggerdef(oid) || ';'
        FROM pg_trigger
        WHERE tgname = #{@connection.quote(trigger)} AND NOT tgisinternal
      SQL
      dump_rollout_database_definition(stream, definition) if definition.present?
    end
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"

  dumper = ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper
  dumper.prepend(CohortReleaseSchemaDumper) unless dumper < CohortReleaseSchemaDumper
end
