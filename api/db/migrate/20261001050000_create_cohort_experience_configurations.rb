# frozen_string_literal: true

require "digest"

class CreateCohortExperienceConfigurations < ActiveRecord::Migration[8.0]
  LEGACY_CONFIG = {
    "schema_version" => 1,
    "optional_modules" => {
      "cfo_filter" => true,
      "optionality" => true
    }
  }.freeze

  def change
    create_table :cohort_experience_configurations do |t|
      t.references :cohort, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :draft_config, null: false, default: {}
      t.integer :draft_revision, null: false, default: 1
      t.string :preview_digest
      t.integer :previewed_draft_revision
      t.datetime :previewed_at
      t.references :last_edited_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :cohort_experience_configurations,
      "jsonb_typeof(draft_config) = 'object'",
      name: "cohort_experience_configurations_draft_object"
    add_check_constraint :cohort_experience_configurations,
      "octet_length(draft_config::text) <= 4096",
      name: "cohort_experience_configurations_draft_bytes"
    add_check_constraint :cohort_experience_configurations,
      "draft_revision > 0",
      name: "cohort_experience_configurations_positive_revision"
    add_check_constraint :cohort_experience_configurations,
      "preview_digest IS NULL OR preview_digest ~ '^[0-9a-f]{64}$'",
      name: "cohort_experience_configurations_preview_digest"
    add_check_constraint :cohort_experience_configurations,
      "(preview_digest IS NULL AND previewed_draft_revision IS NULL AND previewed_at IS NULL) OR (preview_digest IS NOT NULL AND previewed_draft_revision IS NOT NULL AND previewed_at IS NOT NULL)",
      name: "cohort_experience_configurations_preview_complete"

    create_table :cohort_experience_versions do |t|
      t.references :cohort_experience_configuration, null: false, foreign_key: true, index: false
      t.integer :version_number, null: false
      t.jsonb :config, null: false
      t.string :config_digest, null: false
      t.references :published_by_user, null: false, foreign_key: { to_table: :users }
      t.references :source_version, foreign_key: { to_table: :cohort_experience_versions }
      t.timestamps
    end
    add_index :cohort_experience_versions,
      %i[cohort_experience_configuration_id version_number],
      unique: true,
      name: "index_cohort_experience_versions_on_config_and_number"
    add_check_constraint :cohort_experience_versions,
      "jsonb_typeof(config) = 'object'",
      name: "cohort_experience_versions_config_object"
    add_check_constraint :cohort_experience_versions,
      "octet_length(config::text) <= 4096",
      name: "cohort_experience_versions_config_bytes"
    add_check_constraint :cohort_experience_versions,
      "config_digest ~ '^[0-9a-f]{64}$'",
      name: "cohort_experience_versions_digest"
    add_check_constraint :cohort_experience_versions,
      "version_number > 0",
      name: "cohort_experience_versions_positive_number"

    add_reference :cohort_experience_configurations,
      :current_published_version,
      foreign_key: { to_table: :cohort_experience_versions },
      index: true

    create_table :cohort_experience_publication_events do |t|
      t.references :cohort_experience_configuration, null: false, foreign_key: true, index: false
      t.references :cohort_experience_version, null: false, foreign_key: true, index: false
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :source_version, foreign_key: { to_table: :cohort_experience_versions }
      t.string :event_type, null: false
      t.timestamps
    end
    add_index :cohort_experience_publication_events,
      :cohort_experience_configuration_id,
      name: "index_cohort_experience_events_on_configuration"
    add_index :cohort_experience_publication_events,
      :cohort_experience_version_id,
      name: "index_cohort_experience_events_on_version"
    add_check_constraint :cohort_experience_publication_events,
      "event_type IN ('publish', 'rollback')",
      name: "cohort_experience_publication_events_type"

    reversible do |direction|
      direction.up { backfill_existing_cohorts }
    end
  end

  private

  def backfill_existing_cohorts
    config_json = connection.quote(LEGACY_CONFIG.to_json)
    digest = connection.quote(Digest::SHA256.hexdigest(JSON.generate(LEGACY_CONFIG)))
    now = connection.quote(Time.current)

    connection.select_rows("SELECT id, created_by_user_id FROM cohorts ORDER BY id").each do |cohort_id, actor_id|
      configuration_id = connection.select_value(<<~SQL.squish)
        INSERT INTO cohort_experience_configurations
          (cohort_id, draft_config, draft_revision, last_edited_by_user_id, lock_version, created_at, updated_at)
        VALUES
          (#{cohort_id}, #{config_json}::jsonb, 1, #{actor_id}, 0, #{now}, #{now})
        RETURNING id
      SQL
      version_id = connection.select_value(<<~SQL.squish)
        INSERT INTO cohort_experience_versions
          (cohort_experience_configuration_id, version_number, config, config_digest, published_by_user_id, created_at, updated_at)
        VALUES
          (#{configuration_id}, 1, #{config_json}::jsonb, #{digest}, #{actor_id}, #{now}, #{now})
        RETURNING id
      SQL
      execute <<~SQL.squish
        UPDATE cohort_experience_configurations
        SET current_published_version_id = #{version_id}, updated_at = #{now}
        WHERE id = #{configuration_id}
      SQL
      execute <<~SQL.squish
        INSERT INTO cohort_experience_publication_events
          (cohort_experience_configuration_id, cohort_experience_version_id, actor_user_id, event_type, created_at, updated_at)
        VALUES
          (#{configuration_id}, #{version_id}, #{actor_id}, 'publish', #{now}, #{now})
      SQL
    end
  end
end
