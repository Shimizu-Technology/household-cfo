# frozen_string_literal: true

class CreatePersonaReleaseGates < ActiveRecord::Migration[8.0]
  def change
    create_table :coach_persona_release_candidates do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :draft_revision, null: false
      t.string :config_digest, null: false
      t.string :content_manifest_digest, null: false
      t.string :phrase_manifest_digest, null: false
      t.string :audience_digest, null: false
      t.jsonb :audience_snapshot, null: false, default: {}
      t.jsonb :config_snapshot, null: false, default: {}
      t.jsonb :phrase_artifacts_snapshot, null: false, default: []
      t.jsonb :manifest, null: false, default: {}
      t.string :manifest_digest, null: false
      t.datetime :sealed_at, null: false
      t.timestamps
    end
    add_index :coach_persona_release_candidates, %i[coach_persona_id manifest_digest], unique: true,
      name: "idx_persona_release_candidates_manifest"

    create_table :coach_persona_evaluation_cases do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :coach_persona, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :system_key
      t.string :name, null: false
      t.string :case_kind, null: false
      t.text :prompt, null: false
      t.jsonb :assertions, null: false, default: []
      t.boolean :required, null: false, default: false
      t.boolean :active, null: false, default: true
      t.string :case_digest, null: false
      t.string :request_key
      t.string :request_fingerprint
      t.references :retired_by_user, foreign_key: { to_table: :users }
      t.datetime :retired_at
      t.string :retirement_digest
      t.timestamps
    end
    add_index :coach_persona_evaluation_cases, %i[coach_persona_id system_key], unique: true,
      where: "system_key IS NOT NULL", name: "idx_persona_evaluation_cases_system_key"
    add_index :coach_persona_evaluation_cases, :request_key, unique: true,
      where: "request_key IS NOT NULL", name: "idx_persona_evaluation_cases_request_key"

    create_table :coach_persona_evaluation_runs do |t|
      t.references :coach_persona_release_candidate, null: false, foreign_key: true,
        index: { name: "idx_persona_evaluation_runs_candidate" }
      t.references :requested_by_user, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.string :adapter_kind, null: false
      t.string :cases_digest, null: false
      t.string :request_key, null: false
      t.string :request_fingerprint, null: false
      t.datetime :enqueued_at
      t.integer :execution_attempts, null: false, default: 0
      t.string :run_digest
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :coach_persona_evaluation_runs, :request_key, unique: true,
      name: "idx_persona_evaluation_runs_request_key"

    create_table :coach_persona_evaluation_results do |t|
      t.references :coach_persona_evaluation_run, null: false, foreign_key: true,
        index: { name: "idx_persona_evaluation_results_run" }
      t.references :coach_persona_evaluation_case, null: false, foreign_key: true,
        index: { name: "idx_persona_evaluation_results_case" }
      t.string :status, null: false
      t.jsonb :case_snapshot, null: false, default: {}
      t.text :output, null: false, default: ""
      t.jsonb :adapter_metadata, null: false, default: {}
      t.jsonb :assertion_results, null: false, default: []
      t.boolean :fallback_only, null: false, default: false
      t.string :result_digest, null: false
      t.timestamps
    end
    add_index :coach_persona_evaluation_results,
      %i[coach_persona_evaluation_run_id coach_persona_evaluation_case_id], unique: true,
      name: "idx_persona_evaluation_results_unique_case"

    create_table :coach_persona_evaluation_approvals do |t|
      t.references :coach_persona_evaluation_run, null: false, foreign_key: true,
        index: { name: "idx_persona_evaluation_approvals_run", unique: true }
      t.references :reviewed_by_user, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.boolean :self_review, null: false, default: false
      t.string :run_digest, null: false
      t.string :approval_digest, null: false
      t.datetime :reviewed_at, null: false
      t.timestamps
    end

    create_table :coach_phrase_audience_attestations do |t|
      t.references :coach_persona_release_candidate, null: false, foreign_key: true,
        index: { name: "idx_phrase_audience_attestations_candidate" }
      t.references :reviewed_by_user, null: false, foreign_key: { to_table: :users }
      t.uuid :artifact_id, null: false
      t.string :artifact_fingerprint, null: false
      t.string :audience_digest, null: false
      t.string :decision, null: false
      t.boolean :self_review, null: false, default: false
      t.string :attestation_digest, null: false
      t.datetime :reviewed_at, null: false
      t.timestamps
    end
    add_index :coach_phrase_audience_attestations,
      %i[coach_persona_release_candidate_id artifact_id], unique: true,
      name: "idx_phrase_audience_attestations_artifact"

    change_table :coach_persona_versions, bulk: true do |t|
      t.string :release_gate_version, null: false, default: "gate_v1"
      t.references :coach_persona_release_candidate, foreign_key: true,
        index: { name: "idx_persona_versions_release_candidate" }
      t.references :coach_persona_evaluation_run, foreign_key: true,
        index: { name: "idx_persona_versions_evaluation_run" }
      t.references :coach_persona_evaluation_approval, foreign_key: true,
        index: { name: "idx_persona_versions_evaluation_approval" }
      t.string :release_manifest_digest
      t.string :audience_digest
      t.string :release_evidence_digest
    end

    add_column :coach_personas, :release_gate_version, :string, null: false, default: "gate_v1"

    change_table :coach_persona_publication_events, bulk: true do |t|
      t.string :release_gate_version, null: false, default: "gate_v1"
      t.string :release_evidence_digest
    end

    add_check_constraint :coach_persona_evaluation_cases,
      "case_kind IN ('system', 'custom')", name: "persona_evaluation_cases_kind_valid"
    add_check_constraint :coach_persona_evaluation_runs,
      "status IN ('pending', 'running', 'passed', 'failed', 'error')", name: "persona_evaluation_runs_status_valid"
    add_check_constraint :coach_persona_evaluation_results,
      "status IN ('passed', 'failed', 'error')", name: "persona_evaluation_results_status_valid"
    add_check_constraint :coach_persona_evaluation_approvals,
      "decision IN ('approved', 'rejected')", name: "persona_evaluation_approvals_decision_valid"
    add_check_constraint :coach_phrase_audience_attestations,
      "decision IN ('approved', 'rejected')", name: "phrase_audience_attestations_decision_valid"
    add_check_constraint :coach_persona_versions,
      "release_gate_version IN ('gate_v1', 'gate_v2')", name: "persona_versions_release_gate_valid"
    add_check_constraint :coach_persona_publication_events,
      "release_gate_version IN ('gate_v1', 'gate_v2')", name: "persona_publication_events_release_gate_valid"
    add_check_constraint :coach_persona_release_candidates,
      "draft_revision > 0 AND config_digest ~ '^[0-9a-f]{64}$' AND content_manifest_digest ~ '^[0-9a-f]{64}$' AND phrase_manifest_digest ~ '^[0-9a-f]{64}$' AND audience_digest ~ '^[0-9a-f]{64}$' AND manifest_digest ~ '^[0-9a-f]{64}$'",
      name: "persona_release_candidates_digest_shape"
    add_check_constraint :coach_persona_release_candidates,
      "jsonb_typeof(audience_snapshot) = 'object' AND jsonb_typeof(config_snapshot) = 'object' AND jsonb_typeof(phrase_artifacts_snapshot) = 'array' AND jsonb_typeof(manifest) = 'object'",
      name: "persona_release_candidates_json_shape"
    add_check_constraint :coach_persona_evaluation_cases,
      "jsonb_typeof(assertions) = 'array' AND ((case_kind = 'system' AND required = TRUE AND active = TRUE AND system_key IS NOT NULL AND request_key IS NULL AND request_fingerprint IS NULL) OR (case_kind = 'custom' AND system_key IS NULL AND request_key IS NOT NULL AND char_length(request_key) BETWEEN 1 AND 100 AND request_fingerprint ~ '^[0-9a-f]{64}$')) AND ((active = TRUE AND retired_by_user_id IS NULL AND retired_at IS NULL AND retirement_digest IS NULL) OR (active = FALSE AND case_kind = 'custom' AND retired_by_user_id IS NOT NULL AND retired_at IS NOT NULL AND retirement_digest ~ '^[0-9a-f]{64}$'))",
      name: "persona_evaluation_cases_shape"
    add_check_constraint :coach_persona_evaluation_runs,
      "cases_digest ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$' AND char_length(request_key) BETWEEN 1 AND 100 AND execution_attempts >= 0 AND (run_digest IS NULL OR run_digest ~ '^[0-9a-f]{64}$') AND ((status = 'pending' AND started_at IS NULL AND completed_at IS NULL AND run_digest IS NULL) OR (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND run_digest IS NULL) OR (status IN ('passed', 'failed', 'error') AND started_at IS NOT NULL AND completed_at IS NOT NULL AND run_digest IS NOT NULL))",
      name: "persona_evaluation_runs_lifecycle"
    add_check_constraint :coach_persona_evaluation_results,
      "result_digest ~ '^[0-9a-f]{64}$' AND jsonb_typeof(case_snapshot) = 'object' AND jsonb_typeof(adapter_metadata) = 'object' AND jsonb_typeof(assertion_results) = 'array'",
      name: "persona_evaluation_results_shape"
    add_check_constraint :coach_persona_evaluation_approvals,
      "run_digest ~ '^[0-9a-f]{64}$' AND approval_digest ~ '^[0-9a-f]{64}$'",
      name: "persona_evaluation_approvals_digest_shape"
    add_check_constraint :coach_phrase_audience_attestations,
      "artifact_fingerprint ~ '^[0-9a-f]{64}$' AND audience_digest ~ '^[0-9a-f]{64}$' AND attestation_digest ~ '^[0-9a-f]{64}$'",
      name: "phrase_audience_attestations_digest_shape"
    add_check_constraint :coach_persona_versions,
      "(release_gate_version = 'gate_v1' AND coach_persona_release_candidate_id IS NULL AND coach_persona_evaluation_run_id IS NULL AND coach_persona_evaluation_approval_id IS NULL AND release_manifest_digest IS NULL AND audience_digest IS NULL AND release_evidence_digest IS NULL) OR (release_gate_version = 'gate_v2' AND coach_persona_release_candidate_id IS NOT NULL AND coach_persona_evaluation_run_id IS NOT NULL AND coach_persona_evaluation_approval_id IS NOT NULL AND release_manifest_digest ~ '^[0-9a-f]{64}$' AND audience_digest ~ '^[0-9a-f]{64}$' AND release_evidence_digest ~ '^[0-9a-f]{64}$')",
      name: "persona_versions_release_evidence_complete"
    add_check_constraint :coach_personas,
      "release_gate_version IN ('gate_v1', 'gate_v2')", name: "coach_personas_release_gate_valid"
    add_check_constraint :coach_persona_publication_events,
      "(release_gate_version = 'gate_v1' AND release_evidence_digest IS NULL) OR (release_gate_version = 'gate_v2' AND release_evidence_digest ~ '^[0-9a-f]{64}$')",
      name: "persona_publication_events_release_evidence_complete"
  end
end
