# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261002140000_create_coach_workspace_boundaries")

class CreateCoachWorkspaceBoundariesTest < ActiveSupport::TestCase
  test "tenant boundary migration is explicitly irreversible after tenant writes" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      CreateCoachWorkspaceBoundaries.new.down
    end

    assert_includes error.message, "tenant-scoped names"
  end

  test "actual up migrates legacy creators assignments memberships and tenant constraints" do
    with_legacy_schema do |connection|
      seed_legacy_records(connection)

      CreateCoachWorkspaceBoundaries.new.up

      owner_workspace_ids = connection.select_rows(<<~SQL).to_h
        SELECT user_id::text, coach_workspace_id
        FROM coach_workspace_memberships
        WHERE role = 'owner'
      SQL
      assert_equal 4, connection.select_value("SELECT COUNT(*) FROM coach_workspaces").to_i
      assert_equal 4, connection.select_value("SELECT COUNT(*) FROM coach_profiles").to_i
      assert_equal owner_workspace_ids.fetch("2").to_i,
        connection.select_value("SELECT coach_workspace_id FROM cohorts WHERE id = 11").to_i
      assert_equal owner_workspace_ids.fetch("2").to_i,
        connection.select_value("SELECT coach_workspace_id FROM coach_personas WHERE id = 21").to_i
      assert_equal owner_workspace_ids.fetch("3").to_i,
        connection.select_value("SELECT coach_workspace_id FROM coach_content_sources WHERE id = 31").to_i
      assert_equal owner_workspace_ids.fetch("1").to_i,
        connection.select_value("SELECT coach_workspace_id FROM coach_content_items WHERE id = 41").to_i
      assert_equal owner_workspace_ids.fetch("2").to_i,
        connection.select_value("SELECT coach_workspace_id FROM coach_content_packs WHERE id = 51").to_i
      assert_nil connection.select_value("SELECT coach_workspace_id FROM coach_content_items WHERE id = 42")
      assert_equal owner_workspace_ids.fetch("2").to_i,
        connection.select_value("SELECT coach_workspace_id FROM cohort_experience_configurations WHERE id = 61").to_i
      assert_equal owner_workspace_ids.fetch("2").to_i,
        connection.select_value("SELECT coach_workspace_id FROM cohort_persona_assignments WHERE id = 71").to_i

      collaborator = connection.select_one("SELECT role, cohort_managed FROM coach_workspace_memberships WHERE user_id = 4 AND coach_workspace_id = #{owner_workspace_ids.fetch('2')}")
      assert_equal "editor", collaborator.fetch("role")
      assert_equal true, collaborator.fetch("cohort_managed")
      %w[cohorts coach_personas cohort_experience_configurations cohort_persona_assignments].each do |table|
        assert_equal "NO", connection.select_value(<<~SQL.squish)
          SELECT is_nullable FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = '#{table}' AND column_name = 'coach_workspace_id'
        SQL
      end
      %w[
        coach_content_sources_workspace_matches_scope coach_content_items_workspace_matches_scope
        coach_content_packs_workspace_matches_scope fk_experience_configuration_workspace
        fk_persona_assignment_cohort_workspace fk_persona_assignment_persona_workspace
        fk_persona_assignment_version_persona
      ].each do |constraint_name|
        assert connection.select_value(<<~SQL.squish)
          SELECT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = #{connection.quote(constraint_name)}
              AND connamespace = current_schema()::regnamespace
          )
        SQL
      end
    end
  end

  test "actual up aborts before DDL when a legacy creator is no longer staff" do
    with_legacy_schema do |connection|
      seed_legacy_records(connection, demoted_creator: true)

      error = assert_raises(ActiveRecord::MigrationError) do
        CreateCoachWorkspaceBoundaries.new.up
      end

      assert_includes error.message, "3"
      assert_nil connection.select_value("SELECT to_regclass(current_schema() || '.coach_workspaces')")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM coach_content_sources").to_i
    end
  end

  private

  def with_legacy_schema
    connection = ActiveRecord::Base.connection
    original_search_path = connection.schema_search_path
    schema_name = "workspace_migration_#{SecureRandom.hex(6)}"
    connection.execute("CREATE SCHEMA #{connection.quote_table_name(schema_name)}")
    connection.schema_search_path = "#{schema_name},public"
    create_legacy_tables(connection)
    yield connection
  ensure
    connection&.schema_cache&.clear!
    connection.schema_search_path = original_search_path if connection && original_search_path
    connection.execute("DROP SCHEMA IF EXISTS #{connection.quote_table_name(schema_name)} CASCADE") if connection && schema_name
  end

  def create_legacy_tables(connection)
    connection.execute <<~SQL
      CREATE TABLE users (id bigint PRIMARY KEY, email varchar, first_name varchar, last_name varchar, role varchar NOT NULL);
      CREATE TABLE cohorts (id bigint PRIMARY KEY, name varchar NOT NULL, status varchar NOT NULL, created_by_user_id bigint NOT NULL);
      CREATE UNIQUE INDEX index_cohorts_on_lower_name ON cohorts (lower(name));
      CREATE TABLE coach_personas (id bigint PRIMARY KEY, name varchar NOT NULL, created_by_user_id bigint NOT NULL);
      CREATE UNIQUE INDEX index_coach_personas_on_creator_and_lower_name ON coach_personas (created_by_user_id, lower(name));
      CREATE TABLE coach_persona_versions (id bigint PRIMARY KEY, coach_persona_id bigint NOT NULL);
      CREATE TABLE coach_content_sources (id bigint PRIMARY KEY, scope varchar NOT NULL, created_by_user_id bigint NOT NULL, upload_request_id varchar NOT NULL);
      CREATE UNIQUE INDEX idx_content_sources_owner_upload_request ON coach_content_sources (created_by_user_id, upload_request_id);
      CREATE TABLE coach_content_items (id bigint PRIMARY KEY, title varchar NOT NULL, scope varchar NOT NULL, created_by_user_id bigint NOT NULL);
      CREATE UNIQUE INDEX idx_coach_content_items_owner_scope_title ON coach_content_items (created_by_user_id, scope, lower(title));
      CREATE TABLE coach_content_packs (id bigint PRIMARY KEY, name varchar NOT NULL, scope varchar NOT NULL, created_by_user_id bigint NOT NULL);
      CREATE UNIQUE INDEX idx_coach_content_packs_owner_scope_name ON coach_content_packs (created_by_user_id, scope, lower(name));
      CREATE TABLE cohort_experience_configurations (id bigint PRIMARY KEY, cohort_id bigint NOT NULL);
      CREATE TABLE cohort_persona_assignments (id bigint PRIMARY KEY, cohort_id bigint NOT NULL, coach_persona_id bigint NOT NULL, coach_persona_version_id bigint NOT NULL);
      CREATE TABLE cohort_memberships (id bigint PRIMARY KEY, cohort_id bigint NOT NULL, user_id bigint NOT NULL, role varchar NOT NULL);
    SQL
  end

  def seed_legacy_records(connection, demoted_creator: false)
    creator_three_role = demoted_creator ? "participant" : "coach"
    connection.execute <<~SQL
      INSERT INTO users (id, email, first_name, last_name, role) VALUES
        (1, 'owner-one@example.com', 'Owner', 'One', 'coach'),
        (2, 'owner-two@example.com', 'Owner', 'Two', 'coach'),
        (3, 'owner-three@example.com', 'Owner', 'Three', '#{creator_three_role}'),
        (4, 'collaborator@example.com', 'Coach', 'Collaborator', 'coach');
      INSERT INTO cohorts (id, name, status, created_by_user_id) VALUES (11, 'Legacy cohort', 'active', 1);
      INSERT INTO coach_personas (id, name, created_by_user_id) VALUES (21, 'Legacy persona', 2);
      INSERT INTO coach_persona_versions (id, coach_persona_id) VALUES (22, 21);
      INSERT INTO coach_content_sources (id, scope, created_by_user_id, upload_request_id) VALUES (31, 'coach', 3, 'legacy-upload');
      INSERT INTO coach_content_items (id, title, scope, created_by_user_id) VALUES
        (41, 'Legacy item', 'coach', 1), (42, 'Platform item', 'platform', 1);
      INSERT INTO coach_content_packs (id, name, scope, created_by_user_id) VALUES (51, 'Legacy pack', 'coach', 2);
      INSERT INTO cohort_experience_configurations (id, cohort_id) VALUES (61, 11);
      INSERT INTO cohort_persona_assignments (id, cohort_id, coach_persona_id, coach_persona_version_id) VALUES (71, 11, 21, 22);
      INSERT INTO cohort_memberships (id, cohort_id, user_id, role) VALUES (81, 11, 4, 'coach');
    SQL
  end
end
