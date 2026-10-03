# frozen_string_literal: true

class AddBrandToCohortReleaseManifest < ActiveRecord::Migration[8.1]
  def up
    add_column :cohort_releases, :brand_mode, :string
    add_column :cohort_releases, :workspace_brand_version_id, :bigint
    add_column :cohort_releases, :brand_snapshot, :jsonb
    add_column :cohort_releases, :brand_snapshot_digest, :string
    add_index :cohort_releases, :workspace_brand_version_id,
      name: "idx_cohort_releases_brand_version"

    add_foreign_key :cohort_releases, :workspace_brand_versions,
      column: :workspace_brand_version_id, on_delete: :restrict
    execute <<~SQL
      ALTER TABLE cohort_releases
      ADD CONSTRAINT fk_cohort_releases_brand_version
      FOREIGN KEY (workspace_brand_version_id, coach_workspace_id)
      REFERENCES workspace_brand_versions (id, coach_workspace_id)
      ON DELETE RESTRICT
    SQL

    remove_check_constraint :cohort_releases, name: "cohort_releases_manifest_schema_valid"
    add_check_constraint :cohort_releases,
      "manifest_schema IN ('cohort_release_manifest_v1', 'cohort_release_manifest_v2')",
      name: "cohort_releases_manifest_schema_valid"
    add_check_constraint :cohort_releases, <<~SQL.squish, name: "cohort_releases_brand_shape"
      (manifest_schema = 'cohort_release_manifest_v1'
        AND brand_mode IS NULL
        AND workspace_brand_version_id IS NULL
        AND brand_snapshot IS NULL
        AND brand_snapshot_digest IS NULL)
      OR
      (manifest_schema = 'cohort_release_manifest_v2'
        AND brand_snapshot IS NOT NULL
        AND brand_snapshot_digest IS NOT NULL
        AND (
          (brand_mode = 'published_version' AND workspace_brand_version_id IS NOT NULL)
          OR
          (brand_mode = 'legacy_household_cfo_builtin' AND workspace_brand_version_id IS NULL)
        ))
    SQL
    add_check_constraint :cohort_releases,
      "brand_snapshot_digest IS NULL OR brand_snapshot_digest ~ '^[0-9a-f]{64}$'",
      name: "cohort_releases_brand_digest_shape"
    add_check_constraint :cohort_releases,
      "brand_snapshot IS NULL OR jsonb_typeof(brand_snapshot) = 'object'",
      name: "cohort_releases_brand_json_shape"
    add_check_constraint :cohort_releases,
      "brand_snapshot IS NULL OR octet_length(brand_snapshot::text) <= 32768",
      name: "cohort_releases_brand_json_bounded"
  end

  def down
    execute "LOCK TABLE cohort_releases IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM cohort_releases WHERE manifest_schema = 'cohort_release_manifest_v2' LIMIT 1").present?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove v2 brand evidence after cohort releases have been sealed"
    end

    execute "ALTER TABLE cohort_releases DROP CONSTRAINT IF EXISTS fk_cohort_releases_brand_version"
    remove_foreign_key :cohort_releases, column: :workspace_brand_version_id
    remove_check_constraint :cohort_releases, name: "cohort_releases_brand_json_bounded"
    remove_check_constraint :cohort_releases, name: "cohort_releases_brand_json_shape"
    remove_check_constraint :cohort_releases, name: "cohort_releases_brand_digest_shape"
    remove_check_constraint :cohort_releases, name: "cohort_releases_brand_shape"
    remove_check_constraint :cohort_releases, name: "cohort_releases_manifest_schema_valid"
    add_check_constraint :cohort_releases,
      "manifest_schema = 'cohort_release_manifest_v1'",
      name: "cohort_releases_manifest_schema_valid"
    remove_index :cohort_releases, name: "idx_cohort_releases_brand_version"
    remove_columns :cohort_releases, :brand_mode, :workspace_brand_version_id,
      :brand_snapshot, :brand_snapshot_digest
  end
end
