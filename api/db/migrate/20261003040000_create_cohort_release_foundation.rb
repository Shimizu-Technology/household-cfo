# frozen_string_literal: true

class CreateCohortReleaseFoundation < ActiveRecord::Migration[8.1]
  def up
    add_supporting_composite_indexes!

    create_table :cohort_releases do |t|
      t.references :cohort, null: false, foreign_key: { on_delete: :restrict }
      t.references :coach_workspace, null: false, foreign_key: { on_delete: :restrict }
      t.integer :release_number, null: false
      t.string :publication_source, null: false
      t.string :event_type, null: false
      t.references :released_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :actor_role_snapshot
      t.references :source_release, foreign_key: { to_table: :cohort_releases, on_delete: :restrict }

      t.string :persona_mode, null: false
      t.references :coach_persona, foreign_key: { on_delete: :restrict }
      t.references :coach_persona_version, foreign_key: { on_delete: :restrict }
      t.jsonb :persona_snapshot, null: false, default: {}
      t.string :persona_snapshot_digest, null: false

      t.string :experience_mode, null: false
      t.references :cohort_experience_configuration, null: false, foreign_key: { on_delete: :restrict },
        index: { name: "idx_cohort_releases_experience_configuration" }
      t.references :cohort_experience_version, foreign_key: { on_delete: :restrict },
        index: { name: "idx_cohort_releases_experience_version" }
      t.jsonb :experience_snapshot, null: false, default: {}
      t.string :experience_snapshot_digest, null: false

      t.integer :tool_registry_version, null: false
      t.jsonb :tool_registry_snapshot, null: false, default: {}
      t.string :tool_registry_digest, null: false

      t.string :manifest_schema, null: false
      t.jsonb :bundle, null: false, default: {}
      t.string :bundle_digest, null: false
      t.jsonb :manifest, null: false, default: {}
      t.string :manifest_digest, null: false
      t.string :request_key, null: false
      t.string :request_fingerprint, null: false
      t.datetime :released_at, null: false
      t.timestamps
    end

    add_index :cohort_releases, %i[cohort_id release_number], unique: true,
      name: "idx_cohort_releases_number"
    add_index :cohort_releases, %i[cohort_id request_key], unique: true,
      name: "idx_cohort_releases_request_key"
    add_index :cohort_releases, %i[id cohort_id coach_workspace_id], unique: true,
      name: "idx_cohort_releases_id_cohort_workspace"
    add_index :cohort_releases, %i[cohort_id released_at id],
      name: "idx_cohort_releases_history"

    add_check_constraint :cohort_releases,
      "release_number > 0 AND tool_registry_version > 0",
      name: "cohort_releases_positive_versions"
    add_check_constraint :cohort_releases,
      "publication_source IN ('user', 'legacy_backfill', 'system')",
      name: "cohort_releases_publication_source_valid"
    add_check_constraint :cohort_releases,
      "event_type IN ('release', 'restore', 'reconciliation')",
      name: "cohort_releases_event_type_valid"
    add_check_constraint :cohort_releases,
      "(publication_source = 'user' AND released_by_user_id IS NOT NULL AND actor_role_snapshot IN ('platform_admin', 'owner', 'reviewer')) OR " \
        "(publication_source IN ('legacy_backfill', 'system') AND released_by_user_id IS NULL AND actor_role_snapshot IS NULL)",
      name: "cohort_releases_actor_shape"
    add_check_constraint :cohort_releases,
      "(event_type = 'restore' AND source_release_id IS NOT NULL) OR " \
        "(event_type IN ('release', 'reconciliation') AND source_release_id IS NULL)",
      name: "cohort_releases_source_shape"
    add_check_constraint :cohort_releases,
      "persona_mode IN ('published_version', 'neutral_builtin') AND " \
        "((persona_mode = 'published_version' AND coach_persona_id IS NOT NULL AND coach_persona_version_id IS NOT NULL) OR " \
        "(persona_mode = 'neutral_builtin' AND coach_persona_id IS NULL AND coach_persona_version_id IS NULL))",
      name: "cohort_releases_persona_shape"
    add_check_constraint :cohort_releases,
      "experience_mode IN ('published_version', 'safe_default') AND " \
        "((experience_mode = 'published_version' AND cohort_experience_version_id IS NOT NULL) OR " \
        "(experience_mode = 'safe_default' AND cohort_experience_version_id IS NULL))",
      name: "cohort_releases_experience_shape"
    add_check_constraint :cohort_releases,
      "manifest_schema = 'cohort_release_manifest_v1'",
      name: "cohort_releases_manifest_schema_valid"
    add_check_constraint :cohort_releases,
      "char_length(request_key) BETWEEN 1 AND 100",
      name: "cohort_releases_request_key_bounded"
    add_check_constraint :cohort_releases,
      "persona_snapshot_digest ~ '^[0-9a-f]{64}$' AND " \
        "experience_snapshot_digest ~ '^[0-9a-f]{64}$' AND " \
        "tool_registry_digest ~ '^[0-9a-f]{64}$' AND " \
        "bundle_digest ~ '^[0-9a-f]{64}$' AND manifest_digest ~ '^[0-9a-f]{64}$' AND " \
        "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "cohort_releases_digest_shape"
    add_check_constraint :cohort_releases,
      "jsonb_typeof(persona_snapshot) = 'object' AND " \
        "jsonb_typeof(experience_snapshot) = 'object' AND " \
        "jsonb_typeof(tool_registry_snapshot) = 'object' AND " \
        "jsonb_typeof(bundle) = 'object' AND jsonb_typeof(manifest) = 'object'",
      name: "cohort_releases_json_shape"
    add_check_constraint :cohort_releases,
      "octet_length(persona_snapshot::text) <= 65536 AND " \
        "octet_length(experience_snapshot::text) <= 16384 AND " \
        "octet_length(tool_registry_snapshot::text) <= 65536 AND " \
        "octet_length(bundle::text) <= 196608 AND octet_length(manifest::text) <= 262144",
      name: "cohort_releases_json_bounded"

    add_cross_record_constraints!
    add_immutability_trigger!
  end

  def down
    execute "LOCK TABLE cohort_releases IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM cohort_releases LIMIT 1").present?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove immutable cohort release evidence after releases have been sealed"
    end

    drop_table :cohort_releases
    execute "DROP FUNCTION IF EXISTS prevent_cohort_release_mutation()"
    remove_index :cohort_experience_versions, name: "idx_experience_versions_id_configuration"
    remove_index :cohort_experience_configurations, name: "idx_experience_configurations_id_cohort_workspace"
  end

  private

  def add_supporting_composite_indexes!
    add_index :cohort_experience_configurations, %i[id cohort_id coach_workspace_id], unique: true,
      name: "idx_experience_configurations_id_cohort_workspace"
    add_index :cohort_experience_versions, %i[id cohort_experience_configuration_id], unique: true,
      name: "idx_experience_versions_id_configuration"
  end

  def add_cross_record_constraints!
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_cohort_workspace
      FOREIGN KEY (cohort_id, coach_workspace_id)
      REFERENCES cohorts (id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_persona_workspace
      FOREIGN KEY (coach_persona_id, coach_workspace_id)
      REFERENCES coach_personas (id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_persona_version
      FOREIGN KEY (coach_persona_version_id, coach_persona_id)
      REFERENCES coach_persona_versions (id, coach_persona_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_experience_configuration
      FOREIGN KEY (cohort_experience_configuration_id, cohort_id, coach_workspace_id)
      REFERENCES cohort_experience_configurations (id, cohort_id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_experience_version
      FOREIGN KEY (cohort_experience_version_id, cohort_experience_configuration_id)
      REFERENCES cohort_experience_versions (id, cohort_experience_configuration_id)
      ON DELETE RESTRICT
    SQL
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_source
      FOREIGN KEY (source_release_id, cohort_id, coach_workspace_id)
      REFERENCES cohort_releases (id, cohort_id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL
  end

  def add_immutability_trigger!
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
  end
end
