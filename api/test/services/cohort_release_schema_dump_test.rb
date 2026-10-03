# frozen_string_literal: true

require "test_helper"
require "stringio"

class CohortReleaseSchemaDumpTest < ActiveSupport::TestCase
  test "schema dumps preserve repeat-safe cohort release immutability SQL" do
    stream = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    schema = stream.string

    assert_includes schema, "CREATE OR REPLACE FUNCTION prevent_cohort_release_mutation()"
    assert_includes schema, "DROP TRIGGER IF EXISTS cohort_releases_immutable ON cohort_releases;"
    assert_includes schema, "CREATE TRIGGER cohort_releases_immutable"
    assert_operator schema.index("CREATE TRIGGER cohort_releases_immutable"), :<, schema.rindex("end")
    assert_includes schema, "CREATE OR REPLACE FUNCTION prevent_coach_operation_execution_mutation()"
    assert_includes schema, "DROP TRIGGER IF EXISTS coach_operation_executions_immutable ON coach_operation_executions;"
    assert_includes schema, "CREATE TRIGGER coach_operation_executions_immutable"
    assert_operator schema.index("CREATE TRIGGER coach_operation_executions_immutable"), :<, schema.rindex("end")
    assert_includes schema, "CREATE OR REPLACE FUNCTION protect_cohort_rollout_identity()"
    assert_includes schema, "DROP TRIGGER IF EXISTS cohort_rollouts_protect_identity ON cohort_rollouts;"
    assert_includes schema, "CREATE TRIGGER cohort_rollouts_protect_identity"
    assert_includes schema, "CREATE TRIGGER cohorts_open_rollout_lifecycle_guard"
    assert_includes schema, "CREATE TRIGGER cohort_rollouts_cohort_lifecycle_guard"
    assert_includes schema, "FOR UPDATE;"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_waves_immutable"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_participants_immutable"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_participants_limit"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_waves_prevent_append"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_participants_prevent_append"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_transitions_immutable"
    assert_includes schema, "CREATE TRIGGER cohort_rollout_transitions_enforce_append"
    assert_includes schema, "CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_plan_integrity"
    assert_includes schema, "CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_transition_integrity"
    assert_includes schema, "CREATE OR REPLACE FUNCTION public.validate_cohort_rollout_latest_integrity"
    assert_includes schema, "CREATE CONSTRAINT TRIGGER cohort_rollouts_integrity_deferred"
    assert_includes schema, "CREATE CONSTRAINT TRIGGER cohort_rollout_transitions_integrity_deferred"
    assert_includes schema, "CREATE CONSTRAINT TRIGGER coach_operation_rollout_integrity_deferred"
    assert_includes schema, "rollout operation snapshots do not match exact relational evidence"
    assert_operator schema.index("CREATE TRIGGER cohort_rollout_transitions_immutable"), :<, schema.rindex("end")
  end
end
