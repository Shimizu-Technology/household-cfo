# frozen_string_literal: true

class HardenPersonaReleaseEvidence < ActiveRecord::Migration[8.0]
  def change
    create_table :coach_persona_behavioral_preview_evidences do |t|
      t.references :coach_persona_release_candidate, null: false, foreign_key: true,
        index: { name: "idx_persona_behavioral_previews_candidate" }
      t.references :generated_by_user, null: false, foreign_key: { to_table: :users }
      t.text :prompt, null: false
      t.text :output, null: false
      t.string :response_source, null: false
      t.string :model_identifier, null: false
      t.string :privacy_scope, null: false
      t.string :context_digest, null: false
      t.string :candidate_digest, null: false
      t.string :config_digest, null: false
      t.string :content_manifest_digest, null: false
      t.string :phrase_manifest_digest, null: false
      t.string :evidence_digest, null: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :coach_persona_behavioral_preview_evidences, :evidence_digest, unique: true,
      name: "idx_persona_behavioral_previews_digest"
    add_check_constraint :coach_persona_behavioral_preview_evidences,
      "char_length(prompt) BETWEEN 1 AND 2000 AND char_length(output) BETWEEN 1 AND 4000 AND char_length(model_identifier) BETWEEN 1 AND 200 AND response_source = 'live_model' AND privacy_scope = 'no_saved_participant_or_household_data'",
      name: "persona_behavioral_previews_bounded"
    add_check_constraint :coach_persona_behavioral_preview_evidences,
      "context_digest ~ '^[0-9a-f]{64}$' AND candidate_digest ~ '^[0-9a-f]{64}$' AND config_digest ~ '^[0-9a-f]{64}$' AND content_manifest_digest ~ '^[0-9a-f]{64}$' AND phrase_manifest_digest ~ '^[0-9a-f]{64}$' AND evidence_digest ~ '^[0-9a-f]{64}$'",
      name: "persona_behavioral_previews_digest_shape"

    change_table :coach_persona_evaluation_runs, bulk: true do |t|
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.datetime :lease_claimed_at
    end
    add_index :coach_persona_evaluation_runs, :lease_token, unique: true,
      where: "lease_token IS NOT NULL", name: "idx_persona_evaluation_runs_lease_token"

    change_table :coach_persona_evaluation_approvals, bulk: true do |t|
      t.string :reviewer_role_snapshot
      t.jsonb :reviewer_authority_snapshot, null: false, default: {}
      t.string :reviewer_authority_digest
    end
    change_table :coach_phrase_audience_attestations, bulk: true do |t|
      t.string :reviewer_role_snapshot
      t.jsonb :reviewer_authority_snapshot, null: false, default: {}
      t.string :reviewer_authority_digest
    end

    change_table :coach_persona_versions, bulk: true do |t|
      t.references :coach_persona_behavioral_preview_evidence, foreign_key: true,
        index: { name: "idx_persona_versions_behavioral_preview" }
      t.string :behavioral_preview_digest
      t.string :release_evidence_schema
    end
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE coach_persona_versions
          SET release_evidence_schema = 'persona_release_evidence_v2'
          WHERE release_gate_version = 'gate_v2'
        SQL
      end
    end

    add_check_constraint :coach_persona_evaluation_runs,
      "(lease_token IS NULL AND lease_expires_at IS NULL AND heartbeat_at IS NULL AND lease_claimed_at IS NULL) OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND heartbeat_at IS NOT NULL)",
      name: "persona_evaluation_runs_lease_complete"
    add_check_constraint :coach_persona_evaluation_approvals,
      "(reviewer_role_snapshot IS NULL AND reviewer_authority_digest IS NULL AND reviewer_authority_snapshot = '{}'::jsonb) OR (reviewer_role_snapshot IS NOT NULL AND reviewer_authority_digest ~ '^[0-9a-f]{64}$' AND jsonb_typeof(reviewer_authority_snapshot) = 'object')",
      name: "persona_evaluation_approvals_authority_shape"
    add_check_constraint :coach_phrase_audience_attestations,
      "(reviewer_role_snapshot IS NULL AND reviewer_authority_digest IS NULL AND reviewer_authority_snapshot = '{}'::jsonb) OR (reviewer_role_snapshot IS NOT NULL AND reviewer_authority_digest ~ '^[0-9a-f]{64}$' AND jsonb_typeof(reviewer_authority_snapshot) = 'object')",
      name: "phrase_audience_attestations_authority_shape"
    add_check_constraint :coach_persona_versions,
      "(release_gate_version = 'gate_v1' AND release_evidence_schema IS NULL AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL) OR (release_gate_version = 'gate_v2' AND release_evidence_schema IN ('persona_release_evidence_v2', 'persona_release_evidence_v3') AND ((release_evidence_schema = 'persona_release_evidence_v2' AND coach_persona_behavioral_preview_evidence_id IS NULL AND behavioral_preview_digest IS NULL) OR (release_evidence_schema = 'persona_release_evidence_v3' AND coach_persona_behavioral_preview_evidence_id IS NOT NULL AND behavioral_preview_digest ~ '^[0-9a-f]{64}$')))",
      name: "persona_versions_behavioral_preview_shape"
  end
end
