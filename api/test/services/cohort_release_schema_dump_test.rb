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
  end
end
