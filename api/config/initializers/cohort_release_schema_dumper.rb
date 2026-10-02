# frozen_string_literal: true

# Rails' PostgreSQL schema dumper does not preserve functions or triggers. Keep
# the database-level immutability guarantee in schema.rb so a fresh schema load
# enforces the same contract as the migration path.
module CohortReleaseSchemaDumper
  private

  def trailer(stream)
    dump_cohort_release_immutability(stream) if @connection.table_exists?("cohort_releases")
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
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"

  dumper = ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper
  dumper.prepend(CohortReleaseSchemaDumper) unless dumper < CohortReleaseSchemaDumper
end
