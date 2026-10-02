# frozen_string_literal: true

class CreateCoachPersonaSetupConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :coach_persona_setup_sessions do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "active"
      t.integer :base_draft_revision, null: false
      t.string :base_config_digest, null: false
      t.datetime :last_activity_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_persona_setup_sessions, %i[coach_persona_id created_by_user_id], unique: true,
      where: "status = 'active'", name: "idx_persona_setup_sessions_one_active"
    add_index :coach_persona_setup_sessions, %i[id coach_workspace_id], unique: true,
      name: "idx_persona_setup_sessions_id_workspace"
    add_check_constraint :coach_persona_setup_sessions,
      "status IN ('active', 'completed', 'abandoned')", name: "persona_setup_sessions_status_valid"
    add_check_constraint :coach_persona_setup_sessions,
      "base_draft_revision > 0", name: "persona_setup_sessions_revision_positive"
    add_check_constraint :coach_persona_setup_sessions,
      "base_config_digest ~ '^[0-9a-f]{64}$'", name: "persona_setup_sessions_digest_sha256"
    add_foreign_key :coach_persona_setup_sessions, :coach_personas,
      column: %i[coach_persona_id coach_workspace_id], primary_key: %i[id coach_workspace_id],
      name: "fk_persona_setup_session_persona_workspace"

    create_table :coach_persona_setup_turns do |t|
      t.references :coach_persona_setup_session, null: false, foreign_key: true,
        index: { name: "idx_persona_setup_turns_session" }
      t.integer :position, null: false
      t.string :idempotency_key, null: false, limit: 200
      t.string :status, null: false, default: "processing"
      t.integer :base_draft_revision, null: false
      t.string :base_config_digest, null: false
      t.text :user_message, null: false
      t.text :assistant_message
      t.string :error_code
      t.string :provider
      t.string :model
      t.string :prompt_version
      t.string :schema_version
      t.jsonb :usage, null: false, default: {}
      t.timestamps
    end
    add_index :coach_persona_setup_turns, %i[coach_persona_setup_session_id position], unique: true,
      name: "idx_persona_setup_turns_position"
    add_index :coach_persona_setup_turns, %i[coach_persona_setup_session_id idempotency_key], unique: true,
      name: "idx_persona_setup_turns_idempotency"
    add_index :coach_persona_setup_turns, :coach_persona_setup_session_id, unique: true,
      where: "status = 'processing'", name: "idx_persona_setup_turns_one_processing"
    add_index :coach_persona_setup_turns, %i[id coach_persona_setup_session_id], unique: true,
      name: "idx_persona_setup_turns_id_session"
    add_check_constraint :coach_persona_setup_turns,
      "status IN ('processing', 'ready', 'failed', 'stale')", name: "persona_setup_turns_status_valid"
    add_check_constraint :coach_persona_setup_turns,
      "position > 0", name: "persona_setup_turns_position_positive"
    add_check_constraint :coach_persona_setup_turns,
      "base_draft_revision > 0", name: "persona_setup_turns_revision_positive"
    add_check_constraint :coach_persona_setup_turns,
      "base_config_digest ~ '^[0-9a-f]{64}$'", name: "persona_setup_turns_digest_sha256"
    add_check_constraint :coach_persona_setup_turns,
      "char_length(user_message) BETWEEN 1 AND 4000", name: "persona_setup_turns_user_message_length"
    add_check_constraint :coach_persona_setup_turns,
      "assistant_message IS NULL OR char_length(assistant_message) <= 2000", name: "persona_setup_turns_assistant_message_length"
    add_check_constraint :coach_persona_setup_turns,
      "jsonb_typeof(usage) = 'object'", name: "persona_setup_turns_usage_object"
    add_check_constraint :coach_persona_setup_turns,
      "(status <> 'processing' OR (assistant_message IS NULL AND error_code IS NULL)) AND (status <> 'ready' OR (assistant_message IS NOT NULL AND error_code IS NULL)) AND (status <> 'failed' OR error_code IS NOT NULL)",
      name: "persona_setup_turns_state_coherent"
    add_check_constraint :coach_persona_setup_turns,
      "error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 80",
      name: "persona_setup_turns_error_code_length"

    create_table :coach_persona_setup_proposals do |t|
      t.references :coach_persona_setup_session, null: false, foreign_key: true,
        index: { name: "idx_persona_setup_proposals_session" }
      t.references :coach_persona_setup_turn, null: false, foreign_key: true,
        index: { name: "idx_persona_setup_proposals_turn" }
      t.string :status, null: false, default: "pending"
      t.integer :base_draft_revision, null: false
      t.string :base_config_digest, null: false
      t.jsonb :operations, null: false, default: []
      t.jsonb :before_state, null: false, default: {}
      t.jsonb :after_state, null: false, default: {}
      t.string :proposal_digest, null: false
      t.string :prompt_version, null: false
      t.string :schema_version, null: false
      t.references :resolved_by_user, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.string :resolution_idempotency_key, limit: 200
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_persona_setup_proposals, :coach_persona_setup_session_id, unique: true,
      where: "status = 'pending'", name: "idx_persona_setup_proposals_one_pending"
    add_index :coach_persona_setup_proposals, :coach_persona_setup_turn_id, unique: true,
      name: "idx_persona_setup_proposals_one_per_turn"
    add_index :coach_persona_setup_proposals, %i[coach_persona_setup_session_id resolution_idempotency_key], unique: true,
      where: "resolution_idempotency_key IS NOT NULL", name: "idx_persona_setup_proposals_resolution_key"
    add_check_constraint :coach_persona_setup_proposals,
      "status IN ('pending', 'applied', 'rejected', 'superseded', 'stale')", name: "persona_setup_proposals_status_valid"
    add_check_constraint :coach_persona_setup_proposals,
      "base_draft_revision > 0", name: "persona_setup_proposals_revision_positive"
    add_check_constraint :coach_persona_setup_proposals,
      "base_config_digest ~ '^[0-9a-f]{64}$'", name: "persona_setup_proposals_base_digest_sha256"
    add_check_constraint :coach_persona_setup_proposals,
      "proposal_digest ~ '^[0-9a-f]{64}$'", name: "persona_setup_proposals_digest_sha256"
    add_check_constraint :coach_persona_setup_proposals,
      "jsonb_typeof(operations) = 'array' AND jsonb_array_length(operations) <= 24",
      name: "persona_setup_proposals_operations_array"
    add_check_constraint :coach_persona_setup_proposals,
      "jsonb_typeof(before_state) = 'object' AND jsonb_typeof(after_state) = 'object'",
      name: "persona_setup_proposals_states_objects"
    add_check_constraint :coach_persona_setup_proposals,
      "octet_length(operations::text) <= 32768 AND octet_length(before_state::text) <= 65536 AND octet_length(after_state::text) <= 65536",
      name: "persona_setup_proposals_payload_sizes"
    add_check_constraint :coach_persona_setup_proposals,
      "(status = 'pending' AND resolved_by_user_id IS NULL AND resolved_at IS NULL) OR (status <> 'pending' AND resolved_by_user_id IS NOT NULL AND resolved_at IS NOT NULL)",
      name: "persona_setup_proposals_resolution_complete"
    add_check_constraint :coach_persona_setup_proposals,
      "status IN ('pending', 'superseded', 'stale') OR resolution_idempotency_key IS NOT NULL",
      name: "persona_setup_proposals_user_resolution_key_present"
    add_foreign_key :coach_persona_setup_proposals, :coach_persona_setup_turns,
      column: %i[coach_persona_setup_turn_id coach_persona_setup_session_id],
      primary_key: %i[id coach_persona_setup_session_id], name: "fk_persona_setup_proposal_turn_session"
  end
end
