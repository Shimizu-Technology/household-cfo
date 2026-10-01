# frozen_string_literal: true

class CreateCoachContentSources < ActiveRecord::Migration[8.1]
  def change
    create_table :coach_content_sources do |t|
      t.string :scope, null: false, default: "coach"
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "uploading"
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :checksum_sha256, null: false
      t.string :s3_key
      t.string :upload_request_id, null: false
      t.integer :generation, null: false, default: 0
      t.jsonb :processing_metadata, null: false, default: {}
      t.string :error_code
      t.string :error_message
      t.datetime :processed_at
      t.datetime :deletion_requested_at
      t.datetime :source_deleted_at
      t.references :source_deleted_by_user, foreign_key: { to_table: :users }
      t.string :source_delete_error_code
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_content_sources, :s3_key, unique: true, where: "s3_key IS NOT NULL"
    add_index :coach_content_sources, [ :created_by_user_id, :upload_request_id ], unique: true, name: "idx_content_sources_owner_upload_request"
    add_check_constraint :coach_content_sources, "scope IN ('coach', 'platform')", name: "coach_content_sources_scope_valid"
    add_check_constraint :coach_content_sources,
      "status IN ('uploading', 'verifying', 'upload_cleanup', 'queued', 'processing', 'needs_review', 'failed', 'deletion_pending', 'deletion_failed', 'source_deleted')",
      name: "coach_content_sources_status_valid"
    add_check_constraint :coach_content_sources, "byte_size > 0", name: "coach_content_sources_byte_size_positive"
    add_check_constraint :coach_content_sources, "checksum_sha256 ~ '^[0-9a-f]{64}$'", name: "coach_content_sources_checksum_sha256"
    add_check_constraint :coach_content_sources, "generation >= 0", name: "coach_content_sources_generation_nonnegative"

    create_table :coach_content_source_attempts do |t|
      t.references :coach_content_source, null: false, foreign_key: true
      t.integer :generation, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :prompt_version, null: false
      t.string :schema_version, null: false
      t.string :status, null: false, default: "processing"
      t.string :error_code
      t.string :error_message
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :coach_content_source_attempts, [ :coach_content_source_id, :generation ], unique: true, name: "idx_content_source_attempt_generation"
    add_check_constraint :coach_content_source_attempts, "generation > 0", name: "coach_content_source_attempt_generation_positive"
    add_check_constraint :coach_content_source_attempts,
      "status IN ('processing', 'succeeded', 'failed', 'superseded')",
      name: "coach_content_source_attempt_status_valid"
    add_reference :coach_content_sources, :current_attempt, foreign_key: { to_table: :coach_content_source_attempts }, index: true

    create_table :coach_content_source_candidates do |t|
      t.references :coach_content_source, null: false, foreign_key: true
      t.references :coach_content_source_attempt, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :status, null: false, default: "proposed"
      t.string :title, null: false
      t.string :kind, null: false
      t.text :content, null: false
      t.jsonb :topics, null: false, default: []
      t.jsonb :evidence_locator, null: false, default: {}
      t.text :evidence_excerpt, null: false
      t.string :content_digest, null: false
      t.integer :revision, null: false, default: 1
      t.string :safety_code
      t.references :reviewed_by_user, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.references :accepted_content_item, foreign_key: { to_table: :coach_content_items }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_content_source_candidates, [ :coach_content_source_attempt_id, :position ], unique: true, name: "idx_content_source_candidates_position"
    add_check_constraint :coach_content_source_candidates, "position >= 0 AND position < 30", name: "coach_content_source_candidates_position_valid"
    add_check_constraint :coach_content_source_candidates,
      "status IN ('proposed', 'accepted', 'rejected', 'superseded')",
      name: "coach_content_source_candidates_status_valid"
    add_check_constraint :coach_content_source_candidates, "revision > 0", name: "coach_content_source_candidates_revision_positive"
    add_check_constraint :coach_content_source_candidates, "content_digest ~ '^[0-9a-f]{64}$'", name: "coach_content_source_candidates_digest_sha256"
    add_check_constraint :coach_content_source_candidates, "octet_length(content) <= 12000", name: "coach_content_source_candidates_content_bytes"
    add_check_constraint :coach_content_source_candidates, "octet_length(evidence_excerpt) <= 1200", name: "coach_content_source_candidates_excerpt_bytes"
    add_check_constraint :coach_content_source_candidates, "jsonb_typeof(topics) = 'array' AND jsonb_array_length(topics) <= 12", name: "coach_content_source_candidates_topics_bounded"
    add_check_constraint :coach_content_source_candidates, "jsonb_typeof(evidence_locator) = 'object'", name: "coach_content_source_candidates_locator_object"

    create_table :coach_content_item_draft_provenances do |t|
      t.references :coach_content_item, null: false, foreign_key: true, index: { unique: true, name: "idx_content_item_draft_provenance_item" }
      t.references :coach_content_source, null: false, foreign_key: true
      t.references :coach_content_source_attempt, null: false, foreign_key: true
      t.references :coach_content_source_candidate, null: false, foreign_key: true
      t.string :source_filename, null: false
      t.string :source_content_type, null: false
      t.bigint :source_byte_size, null: false
      t.string :source_checksum_sha256, null: false
      t.string :attempt_provider, null: false
      t.string :attempt_model, null: false
      t.string :attempt_prompt_version, null: false
      t.string :attempt_schema_version, null: false
      t.string :candidate_content_digest, null: false
      t.jsonb :evidence_locator, null: false, default: {}
      t.string :evidence_excerpt_digest, null: false
      t.string :provenance_digest, null: false
      t.timestamps
    end

    create_table :coach_content_item_version_provenances do |t|
      t.references :coach_content_item_version, null: false, foreign_key: true, index: { unique: true, name: "idx_content_item_version_provenance_version" }
      t.references :coach_content_source, null: false, foreign_key: true
      t.references :coach_content_source_attempt, null: false, foreign_key: true
      t.references :coach_content_source_candidate, null: false, foreign_key: true
      t.string :source_filename, null: false
      t.string :source_content_type, null: false
      t.bigint :source_byte_size, null: false
      t.string :source_checksum_sha256, null: false
      t.string :attempt_provider, null: false
      t.string :attempt_model, null: false
      t.string :attempt_prompt_version, null: false
      t.string :attempt_schema_version, null: false
      t.string :candidate_content_digest, null: false
      t.jsonb :evidence_locator, null: false, default: {}
      t.string :evidence_excerpt_digest, null: false
      t.string :approved_content_digest, null: false
      t.string :provenance_digest, null: false
      t.timestamps
    end

    %i[coach_content_item_draft_provenances coach_content_item_version_provenances].each do |table|
      add_check_constraint table, "source_byte_size > 0", name: "#{table}_source_size_positive"
      add_check_constraint table, "source_checksum_sha256 ~ '^[0-9a-f]{64}$'", name: "#{table}_source_checksum_sha256"
      add_check_constraint table, "candidate_content_digest ~ '^[0-9a-f]{64}$'", name: "#{table}_candidate_digest_sha256"
      add_check_constraint table, "evidence_excerpt_digest ~ '^[0-9a-f]{64}$'", name: "#{table}_excerpt_digest_sha256"
      add_check_constraint table, "provenance_digest ~ '^[0-9a-f]{64}$'", name: "#{table}_provenance_digest_sha256"
    end
    add_check_constraint :coach_content_item_version_provenances,
      "approved_content_digest ~ '^[0-9a-f]{64}$'",
      name: "content_item_version_provenance_approved_digest_sha256"
  end
end
