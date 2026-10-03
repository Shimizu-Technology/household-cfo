# frozen_string_literal: true

require "digest"
require "json"

class CreateWorkspaceBrandFoundation < ActiveRecord::Migration[8.0]
  DEFAULT_CONFIG = {
    "schema_version" => 1,
    "product_name" => "Household CFO",
    "short_name" => "Household CFO",
    "organization_name" => "Household CFO Method",
    "participant_role_term" => "household CFO",
    "powered_by_name" => "VERA",
    "powered_by_placement" => "header",
    "tagline" => "Your household finance command center",
    "welcome_heading" => "Your household money, in one clear place",
    "welcome_description" => "Plan the month, understand what changed, and make confident decisions with your coach's guidance.",
    "logo_url" => nil,
    "favicon_url" => nil,
    "support" => { "label" => "Contact your coach", "email" => nil, "url" => nil },
    "colors" => {
      "background" => "#f7f2ea", "surface" => "#fffdf8", "surface_muted" => "#fbf7ef",
      "text" => "#1f2421", "text_muted" => "#706d66", "border" => "#e2d9cb",
      "primary" => "#7b4a58", "primary_hover" => "#633944", "primary_soft" => "#f1e2e3",
      "accent" => "#b97352", "on_primary" => "#ffffff", "focus" => "#7b4a58"
    },
    "typography" => { "display" => "cormorant_garamond", "body" => "montserrat" },
    "footer" => {
      "text" => "Household CFO provides educational guidance and is not a substitute for individualized legal, tax, investment, or accounting advice.",
      "privacy_url" => nil,
      "terms_url" => nil
    }
  }.freeze

  def up
    create_brand_tables
    create_domain_tables
    add_relational_guards
    add_immutability_guards
    backfill_existing_workspaces
  end

  def down
    if table_exists?(:workspace_brand_versions) && WorkspaceBrandVersionForMigration.exists?
      raise ActiveRecord::IrreversibleMigration, "Cannot remove immutable workspace brand evidence after versions have been published"
    end

    execute "DROP FUNCTION IF EXISTS prevent_workspace_brand_evidence_mutation() CASCADE"
    drop_table :coach_workspace_domain_events
    drop_table :coach_workspace_domains
    remove_foreign_key :workspace_brand_configurations, name: "fk_workspace_brand_current_version"
    drop_table :workspace_brand_publication_events
    drop_table :workspace_brand_versions
    drop_table :workspace_brand_configurations
  end

  private

  class WorkspaceBrandVersionForMigration < ActiveRecord::Base
    self.table_name = "workspace_brand_versions"
  end

  def create_brand_tables
    create_table :workspace_brand_configurations do |t|
      t.references :coach_workspace, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :draft_config, null: false, default: {}
      t.integer :draft_revision, null: false, default: 1
      t.string :preview_digest
      t.integer :previewed_draft_revision
      t.datetime :previewed_at
      t.references :last_edited_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :workspace_brand_configurations, %i[id coach_workspace_id], unique: true,
      name: "idx_workspace_brand_configs_id_workspace"
    add_check_constraint :workspace_brand_configurations, "jsonb_typeof(draft_config) = 'object'",
      name: "workspace_brand_configurations_draft_object"
    add_check_constraint :workspace_brand_configurations, "octet_length(draft_config::text) <= 16384",
      name: "workspace_brand_configurations_draft_bytes"
    add_check_constraint :workspace_brand_configurations, "draft_revision > 0",
      name: "workspace_brand_configurations_positive_revision"
    add_check_constraint :workspace_brand_configurations,
      "preview_digest IS NULL OR preview_digest ~ '^[0-9a-f]{64}$'",
      name: "workspace_brand_configurations_preview_digest"
    add_check_constraint :workspace_brand_configurations,
      "(preview_digest IS NULL AND previewed_draft_revision IS NULL AND previewed_at IS NULL) OR " \
      "(preview_digest IS NOT NULL AND previewed_draft_revision IS NOT NULL AND previewed_at IS NOT NULL)",
      name: "workspace_brand_configurations_preview_complete"

    create_table :workspace_brand_versions do |t|
      t.references :workspace_brand_configuration, null: false, index: false
      t.references :coach_workspace, null: false, index: false
      t.integer :version_number, null: false
      t.jsonb :config, null: false
      t.string :config_digest, null: false
      t.references :published_by_user, null: false, foreign_key: { to_table: :users }
      t.references :source_version, foreign_key: { to_table: :workspace_brand_versions }
      t.timestamps
    end
    add_index :workspace_brand_versions, %i[workspace_brand_configuration_id version_number], unique: true,
      name: "idx_workspace_brand_versions_config_number"
    add_index :workspace_brand_versions, %i[id coach_workspace_id], unique: true,
      name: "idx_workspace_brand_versions_id_workspace"
    add_index :workspace_brand_versions, %i[id workspace_brand_configuration_id], unique: true,
      name: "idx_workspace_brand_versions_id_config"
    add_check_constraint :workspace_brand_versions, "jsonb_typeof(config) = 'object'",
      name: "workspace_brand_versions_config_object"
    add_check_constraint :workspace_brand_versions, "octet_length(config::text) <= 16384",
      name: "workspace_brand_versions_config_bytes"
    add_check_constraint :workspace_brand_versions, "config_digest ~ '^[0-9a-f]{64}$'",
      name: "workspace_brand_versions_digest"
    add_check_constraint :workspace_brand_versions, "version_number > 0",
      name: "workspace_brand_versions_positive_number"

    add_reference :workspace_brand_configurations, :current_published_version,
      foreign_key: false, index: true

    create_table :workspace_brand_publication_events do |t|
      t.references :workspace_brand_configuration, null: false, index: false
      t.references :coach_workspace, null: false, index: false
      t.references :workspace_brand_version, null: false, index: false
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :source_version, foreign_key: { to_table: :workspace_brand_versions }
      t.string :event_type, null: false
      t.string :idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.timestamps
    end
    add_index :workspace_brand_publication_events, :workspace_brand_configuration_id,
      name: "idx_workspace_brand_events_configuration"
    add_index :workspace_brand_publication_events, :workspace_brand_version_id,
      name: "idx_workspace_brand_events_version"
    add_index :workspace_brand_publication_events,
      %i[workspace_brand_configuration_id idempotency_key], unique: true,
      name: "idx_workspace_brand_events_idempotency"
    add_check_constraint :workspace_brand_publication_events, "event_type IN ('publish', 'rollback')",
      name: "workspace_brand_publication_events_type"
    add_check_constraint :workspace_brand_publication_events, "char_length(idempotency_key) BETWEEN 1 AND 255",
      name: "workspace_brand_publication_events_idempotency_length"
    add_check_constraint :workspace_brand_publication_events, "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "workspace_brand_publication_events_request_fingerprint"
  end

  def create_domain_tables
    create_table :coach_workspace_domains do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.string :hostname, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.boolean :is_primary, null: false, default: false
      t.string :verification_token_digest
      t.datetime :verification_requested_at
      t.datetime :verified_at
      t.datetime :activated_at
      t.datetime :disabled_at
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.references :updated_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_workspace_domains, "lower(hostname)", unique: true,
      name: "idx_coach_workspace_domains_lower_hostname"
    add_index :coach_workspace_domains, :coach_workspace_id, unique: true, where: "is_primary",
      name: "idx_coach_workspace_domains_one_primary"
    add_index :coach_workspace_domains, %i[id coach_workspace_id], unique: true,
      name: "idx_coach_workspace_domains_id_workspace"
    add_check_constraint :coach_workspace_domains,
      "hostname = lower(hostname) AND hostname ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$'",
      name: "coach_workspace_domains_hostname"
    add_check_constraint :coach_workspace_domains, "char_length(hostname) BETWEEN 4 AND 253",
      name: "coach_workspace_domains_hostname_length"
    add_check_constraint :coach_workspace_domains, "kind IN ('managed_subdomain', 'custom')",
      name: "coach_workspace_domains_kind"
    add_check_constraint :coach_workspace_domains, "status IN ('pending', 'verified', 'active', 'disabled')",
      name: "coach_workspace_domains_status"
    add_check_constraint :coach_workspace_domains,
      "verification_token_digest IS NULL OR verification_token_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_workspace_domains_token_digest"
    add_check_constraint :coach_workspace_domains,
      "status NOT IN ('verified', 'active') OR verified_at IS NOT NULL",
      name: "coach_workspace_domains_verified_evidence"
    add_check_constraint :coach_workspace_domains,
      "status <> 'active' OR activated_at IS NOT NULL",
      name: "coach_workspace_domains_active_evidence"
    add_check_constraint :coach_workspace_domains,
      "NOT is_primary OR status = 'active'",
      name: "coach_workspace_domains_primary_active"
    add_check_constraint :coach_workspace_domains,
      "(status = 'disabled') = (disabled_at IS NOT NULL)",
      name: "coach_workspace_domains_disabled_evidence"

    create_table :coach_workspace_domain_events do |t|
      t.references :coach_workspace_domain, null: false, index: false
      t.references :coach_workspace, null: false, index: false
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :coach_workspace_domain_events, :coach_workspace_domain_id,
      name: "idx_coach_workspace_domain_events_domain"
    add_check_constraint :coach_workspace_domain_events,
      "event_type IN ('created', 'verification_requested', 'verified', 'activated', 'disabled')",
      name: "coach_workspace_domain_events_type"
    add_check_constraint :coach_workspace_domain_events, "jsonb_typeof(metadata) = 'object'",
      name: "coach_workspace_domain_events_metadata_object"
    add_check_constraint :coach_workspace_domain_events, "octet_length(metadata::text) <= 4096",
      name: "coach_workspace_domain_events_metadata_bytes"
  end

  def add_relational_guards
    add_foreign_key :workspace_brand_versions, :workspace_brand_configurations,
      column: %i[workspace_brand_configuration_id coach_workspace_id],
      primary_key: %i[id coach_workspace_id], name: "fk_workspace_brand_versions_configuration", on_delete: :restrict
    add_foreign_key :workspace_brand_configurations, :workspace_brand_versions,
      column: %i[current_published_version_id coach_workspace_id],
      primary_key: %i[id coach_workspace_id], name: "fk_workspace_brand_current_version", on_delete: :restrict
    add_foreign_key :workspace_brand_publication_events, :workspace_brand_configurations,
      column: %i[workspace_brand_configuration_id coach_workspace_id],
      primary_key: %i[id coach_workspace_id], name: "fk_workspace_brand_events_configuration", on_delete: :restrict
    add_foreign_key :workspace_brand_publication_events, :workspace_brand_versions,
      column: %i[workspace_brand_version_id workspace_brand_configuration_id],
      primary_key: %i[id workspace_brand_configuration_id], name: "fk_workspace_brand_events_version", on_delete: :restrict
    add_foreign_key :workspace_brand_versions, :workspace_brand_versions,
      column: %i[source_version_id workspace_brand_configuration_id],
      primary_key: %i[id workspace_brand_configuration_id], name: "fk_workspace_brand_versions_source", on_delete: :restrict
    add_foreign_key :workspace_brand_publication_events, :workspace_brand_versions,
      column: %i[source_version_id workspace_brand_configuration_id],
      primary_key: %i[id workspace_brand_configuration_id], name: "fk_workspace_brand_events_source", on_delete: :restrict
    add_foreign_key :coach_workspace_domain_events, :coach_workspace_domains,
      column: %i[coach_workspace_domain_id coach_workspace_id],
      primary_key: %i[id coach_workspace_id], name: "fk_workspace_domain_events_domain", on_delete: :restrict
  end

  def add_immutability_guards
    execute <<~SQL
      CREATE FUNCTION prevent_workspace_brand_evidence_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'workspace brand evidence is immutable';
      END;
      $$ LANGUAGE plpgsql;
    SQL

    %w[workspace_brand_versions workspace_brand_publication_events coach_workspace_domain_events].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_immutable
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION prevent_workspace_brand_evidence_mutation();
      SQL
    end
  end

  def backfill_existing_workspaces
    config_json = connection.quote(DEFAULT_CONFIG.to_json)
    digest = connection.quote(Digest::SHA256.hexdigest(JSON.generate(DEFAULT_CONFIG)))
    now = connection.quote(Time.current)

    connection.select_rows("SELECT id, created_by_user_id FROM coach_workspaces ORDER BY id").each do |workspace_id, actor_id|
      configuration_id = connection.select_value(<<~SQL.squish)
        INSERT INTO workspace_brand_configurations
          (coach_workspace_id, draft_config, draft_revision, last_edited_by_user_id, lock_version, created_at, updated_at)
        VALUES
          (#{workspace_id}, #{config_json}::jsonb, 1, #{actor_id}, 0, #{now}, #{now})
        RETURNING id
      SQL
      version_id = connection.select_value(<<~SQL.squish)
        INSERT INTO workspace_brand_versions
          (workspace_brand_configuration_id, coach_workspace_id, version_number, config, config_digest,
           published_by_user_id, created_at, updated_at)
        VALUES
          (#{configuration_id}, #{workspace_id}, 1, #{config_json}::jsonb, #{digest}, #{actor_id}, #{now}, #{now})
        RETURNING id
      SQL
      execute <<~SQL.squish
        UPDATE workspace_brand_configurations
        SET current_published_version_id = #{version_id}, updated_at = #{now}
        WHERE id = #{configuration_id}
      SQL
      idempotency_key = connection.quote("backfill-workspace-#{workspace_id}-brand-v1")
      request_fingerprint = connection.quote(Digest::SHA256.hexdigest("backfill-workspace-#{workspace_id}-brand-v1"))
      execute <<~SQL.squish
        INSERT INTO workspace_brand_publication_events
          (workspace_brand_configuration_id, coach_workspace_id, workspace_brand_version_id,
           actor_user_id, event_type, idempotency_key, request_fingerprint, created_at, updated_at)
        VALUES
          (#{configuration_id}, #{workspace_id}, #{version_id}, #{actor_id}, 'publish',
           #{idempotency_key}, #{request_fingerprint}, #{now}, #{now})
      SQL
    end
  end
end
