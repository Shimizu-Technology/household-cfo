# frozen_string_literal: true

class CreateCoachContentSourceUrlIntakes < ActiveRecord::Migration[8.1]
  def change
    create_table :coach_content_source_url_intakes do |t|
      t.string :scope, null: false, default: "coach"
      t.references :coach_workspace, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.references :coach_content_source, foreign_key: true
      t.string :request_id, null: false
      t.text :encrypted_url_ciphertext
      t.string :encrypted_url_iv
      t.string :encrypted_url_auth_tag
      t.integer :encryption_key_version, null: false
      t.string :url_identity_hmac, null: false
      t.integer :hmac_key_version, null: false
      t.string :status, null: false, default: "queued"
      t.bigint :reserved_bytes, null: false
      t.string :staging_s3_key
      t.string :final_s3_key
      t.string :resolved_filename
      t.string :resolved_content_type
      t.bigint :fetched_byte_size
      t.string :fetched_checksum_sha256
      t.integer :redirect_count, null: false, default: 0
      t.string :error_code
      t.integer :cleanup_attempts, null: false, default: 0
      t.datetime :fetched_at
      t.datetime :completed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :coach_content_source_url_intakes, :coach_content_source_id,
      unique: true, where: "coach_content_source_id IS NOT NULL",
      name: "idx_url_intakes_registered_source"
    add_index :coach_content_source_url_intakes, %i[coach_workspace_id request_id],
      unique: true, where: "scope = 'coach'", name: "idx_url_intakes_workspace_request"
    add_index :coach_content_source_url_intakes, %i[created_by_user_id request_id],
      unique: true, where: "scope = 'platform'", name: "idx_url_intakes_platform_request"
    add_index :coach_content_source_url_intakes, %i[url_identity_hmac hmac_key_version],
      name: "idx_url_intakes_hmac_version"
    add_index :coach_content_source_url_intakes, %i[status updated_at], name: "idx_url_intakes_recovery"
    add_index :coach_content_source_url_intakes, :staging_s3_key, unique: true, where: "staging_s3_key IS NOT NULL"
    add_index :coach_content_source_url_intakes, :final_s3_key, unique: true, where: "final_s3_key IS NOT NULL"

    add_check_constraint :coach_content_source_url_intakes,
      "scope IN ('coach', 'platform')", name: "url_intakes_scope_valid"
    add_check_constraint :coach_content_source_url_intakes,
      "(scope = 'coach' AND coach_workspace_id IS NOT NULL) OR (scope = 'platform' AND coach_workspace_id IS NULL)",
      name: "url_intakes_workspace_matches_scope"
    add_check_constraint :coach_content_source_url_intakes,
      "status IN ('queued', 'fetching', 'staged', 'registering', 'registered', 'failed', 'cleanup_pending', 'cleanup_failed', 'deleted')",
      name: "url_intakes_status_valid"
    add_check_constraint :coach_content_source_url_intakes,
      "reserved_bytes > 0 AND reserved_bytes <= 12582912", name: "url_intakes_reservation_bounded"
    add_check_constraint :coach_content_source_url_intakes,
      "redirect_count >= 0 AND redirect_count <= 3", name: "url_intakes_redirects_bounded"
    add_check_constraint :coach_content_source_url_intakes,
      "url_identity_hmac ~ '^[0-9a-f]{64}$'", name: "url_intakes_hmac_sha256"
    add_check_constraint :coach_content_source_url_intakes,
      "fetched_checksum_sha256 IS NULL OR fetched_checksum_sha256 ~ '^[0-9a-f]{64}$'",
      name: "url_intakes_checksum_sha256"

    add_column :coach_content_sources, :ingestion_method, :string, null: false, default: "upload"
    add_check_constraint :coach_content_sources,
      "ingestion_method IN ('upload', 'url_snapshot')", name: "coach_content_sources_ingestion_method_valid"
  end
end
