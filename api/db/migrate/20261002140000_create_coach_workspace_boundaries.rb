# frozen_string_literal: true

class CreateCoachWorkspaceBoundaries < ActiveRecord::Migration[8.1]
  COACH_ROOT_TABLES = %i[cohorts coach_personas].freeze
  SCOPED_CONTENT_TABLES = %i[coach_content_sources coach_content_items coach_content_packs].freeze

  def up
    create_table :coach_workspaces do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.references :created_by_user, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_workspaces, "lower(slug)", unique: true, name: "index_coach_workspaces_on_lower_slug"

    create_table :coach_workspace_memberships do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false, default: "viewer"
      t.boolean :cohort_managed, null: false, default: false
      t.timestamps
    end
    add_index :coach_workspace_memberships, %i[coach_workspace_id user_id], unique: true,
      name: "index_coach_workspace_memberships_unique_user"
    add_check_constraint :coach_workspace_memberships,
      "role IN ('owner', 'editor', 'reviewer', 'viewer')",
      name: "coach_workspace_memberships_role_valid"

    create_table :coach_profiles do |t|
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :display_name, null: false
      t.string :title, null: false, default: "Financial coach"
      t.text :bio
      t.references :last_edited_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_check_constraint :coach_profiles, "char_length(display_name) BETWEEN 1 AND 120",
      name: "coach_profiles_display_name_length"
    add_check_constraint :coach_profiles, "char_length(title) BETWEEN 1 AND 160",
      name: "coach_profiles_title_length"
    add_check_constraint :coach_profiles, "bio IS NULL OR char_length(bio) <= 2000",
      name: "coach_profiles_bio_length"

    COACH_ROOT_TABLES.each { |table| add_reference table, :coach_workspace, foreign_key: true }
    SCOPED_CONTENT_TABLES.each { |table| add_reference table, :coach_workspace, foreign_key: true }
    add_reference :cohort_experience_configurations, :coach_workspace, foreign_key: true
    add_reference :cohort_persona_assignments, :coach_workspace, foreign_key: true

    backfill_workspaces!

    COACH_ROOT_TABLES.each { |table| change_column_null table, :coach_workspace_id, false }
    change_column_null :cohort_experience_configurations, :coach_workspace_id, false
    change_column_null :cohort_persona_assignments, :coach_workspace_id, false

    SCOPED_CONTENT_TABLES.each do |table|
      add_check_constraint table,
        "(scope = 'platform' AND coach_workspace_id IS NULL) OR (scope = 'coach' AND coach_workspace_id IS NOT NULL)",
        name: "#{table}_workspace_matches_scope"
    end

    replace_owner_uniqueness_indexes!
    add_cross_workspace_constraints!
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "coach workspace tenant data and tenant-scoped names cannot be mapped safely back to creator-owned records"
  end

  private

  def backfill_workspaces!
    staff_rows = select_all(<<~SQL)
      SELECT id, email, first_name, last_name
      FROM users
      WHERE role IN ('admin', 'coach')
      ORDER BY id
    SQL

    staff_rows.each do |user|
      user_id = user.fetch("id").to_i
      display_name = [ user["first_name"], user["last_name"] ].compact_blank.join(" ").presence || "your coach"
      workspace_name = display_name == "your coach" ? "Coaching workspace" : "#{display_name}'s coaching workspace"
      slug = "coach-workspace-#{user_id}"
      quoted_name = connection.quote(workspace_name)
      quoted_slug = connection.quote(slug)
      quoted_display_name = connection.quote(display_name)

      execute <<~SQL
        INSERT INTO coach_workspaces (name, slug, created_by_user_id, lock_version, created_at, updated_at)
        VALUES (#{quoted_name}, #{quoted_slug}, #{user_id}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      workspace_id = select_value("SELECT id FROM coach_workspaces WHERE slug = #{quoted_slug}").to_i
      execute <<~SQL
        INSERT INTO coach_workspace_memberships (coach_workspace_id, user_id, role, cohort_managed, created_at, updated_at)
        VALUES (#{workspace_id}, #{user_id}, 'owner', FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
      execute <<~SQL
        INSERT INTO coach_profiles (coach_workspace_id, display_name, title, last_edited_by_user_id, created_at, updated_at)
        VALUES (#{workspace_id}, #{quoted_display_name}, 'Financial coach', #{user_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end

    COACH_ROOT_TABLES.each do |table|
      execute <<~SQL
        UPDATE #{table}
        SET coach_workspace_id = memberships.coach_workspace_id
        FROM coach_workspace_memberships memberships
        WHERE memberships.user_id = #{table}.created_by_user_id
          AND memberships.role = 'owner'
      SQL
    end

    SCOPED_CONTENT_TABLES.each do |table|
      execute <<~SQL
        UPDATE #{table}
        SET coach_workspace_id = memberships.coach_workspace_id
        FROM coach_workspace_memberships memberships
        WHERE #{table}.scope = 'coach'
          AND memberships.user_id = #{table}.created_by_user_id
          AND memberships.role = 'owner'
      SQL
    end

    # A legacy platform administrator could assign a coach-owned persona to a
    # cohort created by someone else. Keep that live relationship intact by
    # placing an assigned cohort in the persona's workspace before enforcing
    # the tenant foreign keys. Unassigned cohorts stay with their creator.
    execute <<~SQL
      UPDATE cohorts
      SET coach_workspace_id = personas.coach_workspace_id
      FROM cohort_persona_assignments assignments
      INNER JOIN coach_personas personas ON personas.id = assignments.coach_persona_id
      WHERE assignments.cohort_id = cohorts.id
        AND cohorts.coach_workspace_id <> personas.coach_workspace_id
    SQL

    execute <<~SQL
      UPDATE cohort_experience_configurations configurations
      SET coach_workspace_id = cohorts.coach_workspace_id
      FROM cohorts
      WHERE configurations.cohort_id = cohorts.id
    SQL
    execute <<~SQL
      UPDATE cohort_persona_assignments assignments
      SET coach_workspace_id = cohorts.coach_workspace_id
      FROM cohorts
      WHERE assignments.cohort_id = cohorts.id
    SQL

    execute <<~SQL
      INSERT INTO coach_workspace_memberships (coach_workspace_id, user_id, role, cohort_managed, created_at, updated_at)
      SELECT DISTINCT cohorts.coach_workspace_id, memberships.user_id, 'editor', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cohort_memberships memberships
      INNER JOIN cohorts ON cohorts.id = memberships.cohort_id
      INNER JOIN users ON users.id = memberships.user_id
      WHERE memberships.role IN ('coach', 'admin')
        AND users.role = 'coach'
      ON CONFLICT (coach_workspace_id, user_id) DO NOTHING
    SQL
    execute <<~SQL
      INSERT INTO coach_workspace_memberships (coach_workspace_id, user_id, role, cohort_managed, created_at, updated_at)
      SELECT DISTINCT cohorts.coach_workspace_id, cohorts.created_by_user_id, 'editor', FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cohorts
      INNER JOIN users ON users.id = cohorts.created_by_user_id
      WHERE users.role = 'coach'
      ON CONFLICT (coach_workspace_id, user_id) DO NOTHING
    SQL
  end

  def replace_owner_uniqueness_indexes!
    remove_index :cohorts, name: "index_cohorts_on_lower_name"
    add_index :cohorts, "coach_workspace_id, lower((name)::text)", unique: true,
      name: "index_cohorts_on_workspace_and_lower_name"

    remove_index :coach_personas, name: "index_coach_personas_on_creator_and_lower_name"
    add_index :coach_personas, "coach_workspace_id, lower((name)::text)", unique: true,
      name: "index_coach_personas_on_workspace_and_lower_name"

    remove_index :coach_content_items, name: "idx_coach_content_items_owner_scope_title"
    add_index :coach_content_items, "coach_workspace_id, lower((title)::text)", unique: true,
      where: "scope = 'coach'", name: "idx_coach_content_items_workspace_title"
    add_index :coach_content_items, "created_by_user_id, lower((title)::text)", unique: true,
      where: "scope = 'platform'", name: "idx_platform_content_items_owner_title"

    remove_index :coach_content_packs, name: "idx_coach_content_packs_owner_scope_name"
    add_index :coach_content_packs, "coach_workspace_id, lower((name)::text)", unique: true,
      where: "scope = 'coach'", name: "idx_coach_content_packs_workspace_name"
    add_index :coach_content_packs, "created_by_user_id, lower((name)::text)", unique: true,
      where: "scope = 'platform'", name: "idx_platform_content_packs_owner_name"

    remove_index :coach_content_sources, name: "idx_content_sources_owner_upload_request"
    add_index :coach_content_sources, %i[coach_workspace_id upload_request_id], unique: true,
      where: "scope = 'coach'", name: "idx_coach_content_sources_workspace_request"
    add_index :coach_content_sources, %i[created_by_user_id upload_request_id], unique: true,
      where: "scope = 'platform'", name: "idx_platform_content_sources_owner_request"
  end

  def add_cross_workspace_constraints!
    add_index :cohorts, %i[id coach_workspace_id], unique: true, name: "idx_cohorts_id_workspace"
    add_index :coach_personas, %i[id coach_workspace_id], unique: true, name: "idx_personas_id_workspace"
    add_index :coach_persona_versions, %i[id coach_persona_id], unique: true, name: "idx_persona_versions_id_persona"
    execute <<~SQL
      ALTER TABLE cohort_experience_configurations
      ADD CONSTRAINT fk_experience_configuration_workspace
      FOREIGN KEY (cohort_id, coach_workspace_id)
      REFERENCES cohorts (id, coach_workspace_id)
    SQL
    execute <<~SQL
      ALTER TABLE cohort_persona_assignments
      ADD CONSTRAINT fk_persona_assignment_cohort_workspace
      FOREIGN KEY (cohort_id, coach_workspace_id)
      REFERENCES cohorts (id, coach_workspace_id)
    SQL
    execute <<~SQL
      ALTER TABLE cohort_persona_assignments
      ADD CONSTRAINT fk_persona_assignment_persona_workspace
      FOREIGN KEY (coach_persona_id, coach_workspace_id)
      REFERENCES coach_personas (id, coach_workspace_id)
    SQL
    execute <<~SQL
      ALTER TABLE cohort_persona_assignments
      ADD CONSTRAINT fk_persona_assignment_version_persona
      FOREIGN KEY (coach_persona_version_id, coach_persona_id)
      REFERENCES coach_persona_versions (id, coach_persona_id)
    SQL
  end

  def remove_cross_workspace_constraints!
    execute "ALTER TABLE cohort_persona_assignments DROP CONSTRAINT IF EXISTS fk_persona_assignment_version_persona"
    execute "ALTER TABLE cohort_persona_assignments DROP CONSTRAINT IF EXISTS fk_persona_assignment_persona_workspace"
    execute "ALTER TABLE cohort_persona_assignments DROP CONSTRAINT IF EXISTS fk_persona_assignment_cohort_workspace"
    execute "ALTER TABLE cohort_experience_configurations DROP CONSTRAINT IF EXISTS fk_experience_configuration_workspace"
    remove_index :coach_persona_versions, name: "idx_persona_versions_id_persona"
    remove_index :coach_personas, name: "idx_personas_id_workspace"
    remove_index :cohorts, name: "idx_cohorts_id_workspace"
  end
end
