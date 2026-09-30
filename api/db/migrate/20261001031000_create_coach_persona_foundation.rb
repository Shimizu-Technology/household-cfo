# frozen_string_literal: true

class CreateCoachPersonaFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :coach_personas do |t|
      t.string :name, null: false
      t.text :description
      t.jsonb :draft_config, null: false, default: {}
      t.string :preview_digest
      t.datetime :previewed_at
      t.integer :previewed_draft_revision
      t.integer :draft_revision, null: false, default: 1
      t.datetime :archived_at
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end
    add_index :coach_personas,
      "created_by_user_id, lower(name)",
      unique: true,
      name: "index_coach_personas_on_creator_and_lower_name"
    add_index :coach_personas, :archived_at
    add_check_constraint :coach_personas, "jsonb_typeof(draft_config) = 'object'", name: "coach_personas_draft_config_object"
    # PostgreSQL's jsonb::text adds separator whitespace that compact JSON does not.
    # The application still enforces a 32 KiB compact JSON limit.
    add_check_constraint :coach_personas, "octet_length(draft_config::text) <= 36864", name: "coach_personas_draft_config_bytes"
    add_check_constraint :coach_personas,
      "preview_digest IS NULL OR preview_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_personas_preview_digest_sha256"
    add_check_constraint :coach_personas, "draft_revision > 0", name: "coach_personas_positive_draft_revision"
    add_check_constraint :coach_personas,
      "(preview_digest IS NULL AND previewed_at IS NULL AND previewed_draft_revision IS NULL) OR " \
        "(preview_digest IS NOT NULL AND previewed_at IS NOT NULL AND previewed_draft_revision IS NOT NULL)",
      name: "coach_personas_preview_fields_complete"

    create_table :coach_persona_versions do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.jsonb :config, null: false
      t.string :config_digest, null: false
      t.references :published_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :source_version_id

      t.timestamps
    end
    add_index :coach_persona_versions, [ :coach_persona_id, :version_number ], unique: true, name: "index_coach_persona_versions_on_persona_and_number"
    add_index :coach_persona_versions, :source_version_id
    add_foreign_key :coach_persona_versions, :coach_persona_versions, column: :source_version_id
    add_check_constraint :coach_persona_versions, "version_number > 0", name: "coach_persona_versions_positive_number"
    add_check_constraint :coach_persona_versions, "jsonb_typeof(config) = 'object'", name: "coach_persona_versions_config_object"
    add_check_constraint :coach_persona_versions, "octet_length(config::text) <= 36864", name: "coach_persona_versions_config_bytes"
    add_check_constraint :coach_persona_versions,
      "config_digest ~ '^[0-9a-f]{64}$'",
      name: "coach_persona_versions_digest_sha256"

    add_reference :coach_personas,
      :current_published_version,
      foreign_key: { to_table: :coach_persona_versions },
      index: { name: "index_coach_personas_on_current_published_version_id" }

    create_table :coach_persona_publication_events do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :coach_persona_version, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.bigint :source_version_id

      t.timestamps
    end
    add_index :coach_persona_publication_events, :source_version_id
    add_foreign_key :coach_persona_publication_events, :coach_persona_versions, column: :source_version_id
    add_check_constraint :coach_persona_publication_events,
      "event_type IN ('publish', 'rollback')",
      name: "coach_persona_publication_events_type_valid"

    create_table :cohort_persona_assignments do |t|
      t.references :cohort, null: false, foreign_key: true, index: { unique: true }
      t.references :coach_persona, null: false, foreign_key: true
      t.references :coach_persona_version, null: false, foreign_key: true
      t.references :assigned_by_user, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_reference :chat_messages, :coach_persona_version
    add_foreign_key :chat_messages, :coach_persona_versions, validate: false
    add_column :chat_messages, :assistant_author, :string
    add_check_constraint :chat_messages,
      "(assistant_author IS NULL OR role = 'assistant') AND " \
        "(coach_persona_version_id IS NULL OR (role = 'assistant' AND assistant_author IS NOT NULL))",
      name: "chat_messages_persona_attribution_complete",
      validate: false
    add_check_constraint :chat_messages,
      "assistant_author IS NULL OR char_length(assistant_author) BETWEEN 1 AND 80",
      name: "chat_messages_assistant_author_length",
      validate: false
  end
end
