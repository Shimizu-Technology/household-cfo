# frozen_string_literal: true

class CreateApprovedSourcePhrasePromotions < ActiveRecord::Migration[8.1]
  EMPTY_MANIFEST_DIGEST = "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

  def change
    create_table :coach_phrase_proposals do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :coach_content_source, null: false, foreign_key: true
      t.references :coach_content_source_attempt, null: false, foreign_key: true
      t.references :coach_content_source_candidate, null: false, foreign_key: true
      t.references :coach_content_item_version, null: false, foreign_key: true
      t.references :proposed_by_user, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "draft"
      t.jsonb :phrase_payload, null: false, default: {}
      t.jsonb :evidence_locator, null: false, default: {}
      t.bigint :evidence_start_byte, null: false
      t.bigint :evidence_end_byte, null: false
      t.string :source_checksum_sha256, null: false
      t.string :source_segment_digest, null: false
      t.string :phrase_digest, null: false
      t.string :approved_content_digest, null: false
      t.string :source_provenance_digest, null: false
      t.string :proposal_digest, null: false
      t.integer :revision, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.datetime :submitted_at
      t.datetime :superseded_at
      t.timestamps
    end
    add_index :coach_phrase_proposals, %i[coach_workspace_id proposal_digest], unique: true,
      name: "idx_phrase_proposals_workspace_digest"
    add_index :coach_phrase_proposals, %i[coach_content_source_id status],
      name: "idx_phrase_proposals_source_status"
    add_check_constraint :coach_phrase_proposals,
      "status IN ('draft', 'submitted', 'rejected', 'superseded')", name: "phrase_proposals_status_valid"
    add_check_constraint :coach_phrase_proposals,
      "jsonb_typeof(phrase_payload) = 'object'", name: "phrase_proposals_payload_object"
    add_check_constraint :coach_phrase_proposals,
      "jsonb_typeof(evidence_locator) = 'object'", name: "phrase_proposals_locator_object"
    add_check_constraint :coach_phrase_proposals,
      "evidence_start_byte >= 0 AND evidence_end_byte > evidence_start_byte",
      name: "phrase_proposals_evidence_offsets_valid"
    add_check_constraint :coach_phrase_proposals,
      "revision > 0", name: "phrase_proposals_revision_positive"
    add_check_constraint :coach_phrase_proposals,
      "source_checksum_sha256 ~ '^[0-9a-f]{64}$' AND source_segment_digest ~ '^[0-9a-f]{64}$' AND phrase_digest ~ '^[0-9a-f]{64}$' AND approved_content_digest ~ '^[0-9a-f]{64}$' AND source_provenance_digest ~ '^[0-9a-f]{64}$' AND proposal_digest ~ '^[0-9a-f]{64}$'",
      name: "phrase_proposals_digests_sha256"
    add_check_constraint :coach_phrase_proposals,
      "octet_length(phrase_payload::text) <= 4096 AND octet_length(evidence_locator::text) <= 2048",
      name: "phrase_proposals_payload_sizes"
    add_check_constraint :coach_phrase_proposals,
      "(status IN ('draft', 'superseded')) OR submitted_at IS NOT NULL",
      name: "phrase_proposals_submission_coherent"
    add_check_constraint :coach_phrase_proposals,
      "(status = 'superseded' AND superseded_at IS NOT NULL) OR (status <> 'superseded' AND superseded_at IS NULL)",
      name: "phrase_proposals_supersession_coherent"

    create_table :coach_phrase_attestations do |t|
      t.references :coach_phrase_proposal, null: false, foreign_key: true, index: { unique: true }
      t.references :reviewed_by_user, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.boolean :self_review, null: false, default: false
      t.string :proposal_digest, null: false
      t.string :evidence_digest, null: false
      t.string :attestation_digest, null: false
      t.datetime :reviewed_at, null: false
      t.timestamps
    end
    add_check_constraint :coach_phrase_attestations,
      "decision IN ('approved', 'rejected')", name: "phrase_attestations_decision_valid"
    add_check_constraint :coach_phrase_attestations,
      "proposal_digest ~ '^[0-9a-f]{64}$' AND evidence_digest ~ '^[0-9a-f]{64}$' AND attestation_digest ~ '^[0-9a-f]{64}$'",
      name: "phrase_attestations_digests_sha256"

    create_table :coach_persona_phrase_promotions do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :coach_phrase_proposal, null: false, foreign_key: true
      t.references :coach_phrase_attestation, null: false, foreign_key: true
      t.references :promoted_by_user, null: false, foreign_key: { to_table: :users }
      t.uuid :artifact_id, null: false
      t.jsonb :artifact, null: false, default: {}
      t.string :artifact_fingerprint, null: false
      t.string :promotion_digest, null: false
      t.datetime :promoted_at, null: false
      t.timestamps
    end
    add_index :coach_persona_phrase_promotions, %i[coach_persona_id coach_phrase_proposal_id], unique: true,
      name: "idx_phrase_promotions_persona_proposal"
    add_index :coach_persona_phrase_promotions, %i[coach_persona_id artifact_id], unique: true,
      name: "idx_phrase_promotions_persona_artifact"
    add_check_constraint :coach_persona_phrase_promotions,
      "jsonb_typeof(artifact) = 'object'", name: "phrase_promotions_artifact_object"
    add_check_constraint :coach_persona_phrase_promotions,
      "octet_length(artifact::text) <= 4096", name: "phrase_promotions_artifact_size"
    add_check_constraint :coach_persona_phrase_promotions,
      "artifact_fingerprint ~ '^[0-9a-f]{64}$' AND promotion_digest ~ '^[0-9a-f]{64}$'",
      name: "phrase_promotions_digests_sha256"

    create_table :coach_persona_version_phrase_artifacts do |t|
      t.references :coach_persona_version, null: false, foreign_key: true,
        index: { name: "idx_persona_version_phrase_links_version" }
      t.references :coach_persona_phrase_promotion, null: false, foreign_key: true,
        index: { name: "idx_persona_version_phrase_links_promotion" }
      t.integer :position, null: false
      t.uuid :artifact_id, null: false
      t.string :artifact_fingerprint, null: false
      t.string :promotion_digest, null: false
      t.timestamps
    end
    add_index :coach_persona_version_phrase_artifacts, %i[coach_persona_version_id position], unique: true,
      name: "idx_persona_version_phrase_links_position"
    add_index :coach_persona_version_phrase_artifacts, %i[coach_persona_version_id artifact_id], unique: true,
      name: "idx_persona_version_phrase_links_artifact"
    add_check_constraint :coach_persona_version_phrase_artifacts,
      "position >= 0", name: "persona_version_phrase_links_position_nonnegative"
    add_check_constraint :coach_persona_version_phrase_artifacts,
      "artifact_fingerprint ~ '^[0-9a-f]{64}$' AND promotion_digest ~ '^[0-9a-f]{64}$'",
      name: "persona_version_phrase_links_digests_sha256"

    add_column :coach_persona_versions, :phrase_manifest_digest, :string,
      null: false, default: EMPTY_MANIFEST_DIGEST
    add_check_constraint :coach_persona_versions,
      "phrase_manifest_digest ~ '^[0-9a-f]{64}$'", name: "coach_persona_versions_phrase_manifest_sha256"
  end
end
