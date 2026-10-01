# frozen_string_literal: true

class CreateCoachContentLibrary < ActiveRecord::Migration[8.1]
  def change
    create_table :coach_content_items do |t|
      t.string :title, null: false
      t.string :scope, null: false, default: "coach"
      t.string :kind, null: false
      t.text :draft_content, null: false
      t.boolean :draft_always_on, null: false, default: false
      t.integer :draft_revision, null: false, default: 1
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.datetime :archived_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_content_items,
      "created_by_user_id, scope, lower(title)",
      unique: true,
      name: "idx_coach_content_items_owner_scope_title"
    add_check_constraint :coach_content_items, "scope IN ('coach', 'platform')", name: "coach_content_items_scope_valid"
    add_check_constraint :coach_content_items,
      "kind IN ('guidance', 'script', 'example', 'phrase', 'culture', 'finance_reference')",
      name: "coach_content_items_kind_valid"
    add_check_constraint :coach_content_items, "draft_revision > 0", name: "coach_content_items_revision_positive"
    add_check_constraint :coach_content_items, "octet_length(draft_content) <= 12000", name: "coach_content_items_content_bytes"

    create_table :coach_content_item_versions do |t|
      t.references :coach_content_item, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.string :title, null: false
      t.string :kind, null: false
      t.text :content, null: false
      t.boolean :always_on, null: false, default: false
      t.string :content_digest, null: false
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :coach_content_item_versions, [ :coach_content_item_id, :version_number ], unique: true, name: "idx_content_item_versions_number"
    add_index :coach_content_item_versions, :content_digest
    add_check_constraint :coach_content_item_versions, "version_number > 0", name: "coach_content_item_versions_number_positive"
    add_check_constraint :coach_content_item_versions, "content_digest ~ '^[0-9a-f]{64}$'", name: "coach_content_item_versions_digest_sha256"
    add_check_constraint :coach_content_item_versions, "octet_length(content) <= 12000", name: "coach_content_item_versions_content_bytes"
    add_reference :coach_content_items, :current_approved_version, foreign_key: { to_table: :coach_content_item_versions }, index: { name: "idx_content_items_current_version" }

    create_table :coach_content_packs do |t|
      t.string :name, null: false
      t.text :description
      t.string :scope, null: false, default: "coach"
      t.string :pack_kind, null: false
      t.integer :draft_revision, null: false, default: 1
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.datetime :archived_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :coach_content_packs,
      "created_by_user_id, scope, lower(name)",
      unique: true,
      name: "idx_coach_content_packs_owner_scope_name"
    add_check_constraint :coach_content_packs, "scope IN ('coach', 'platform')", name: "coach_content_packs_scope_valid"
    add_check_constraint :coach_content_packs,
      "pack_kind IN ('voice_culture', 'coaching_method', 'finance_reference')",
      name: "coach_content_packs_kind_valid"
    add_check_constraint :coach_content_packs, "draft_revision > 0", name: "coach_content_packs_revision_positive"

    create_table :coach_content_pack_draft_entries do |t|
      t.references :coach_content_pack, null: false, foreign_key: true
      t.references :coach_content_item_version, null: false, foreign_key: true
      t.integer :position, null: false
      t.timestamps
    end
    add_index :coach_content_pack_draft_entries, [ :coach_content_pack_id, :position ], unique: true, name: "idx_pack_draft_entries_position"
    add_index :coach_content_pack_draft_entries, [ :coach_content_pack_id, :coach_content_item_version_id ], unique: true, name: "idx_pack_draft_entries_item_version"
    add_check_constraint :coach_content_pack_draft_entries, "position >= 0", name: "coach_content_pack_draft_entries_position_nonnegative"

    create_table :coach_content_pack_versions do |t|
      t.references :coach_content_pack, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.string :name, null: false
      t.text :description
      t.string :scope, null: false
      t.string :pack_kind, null: false
      t.string :content_digest, null: false
      t.references :published_by_user, null: false, foreign_key: { to_table: :users }
      t.datetime :sealed_at
      t.timestamps
    end
    add_index :coach_content_pack_versions, [ :coach_content_pack_id, :version_number ], unique: true, name: "idx_content_pack_versions_number"
    add_check_constraint :coach_content_pack_versions, "version_number > 0", name: "coach_content_pack_versions_number_positive"
    add_check_constraint :coach_content_pack_versions, "content_digest ~ '^[0-9a-f]{64}$'", name: "coach_content_pack_versions_digest_sha256"
    add_reference :coach_content_packs, :current_published_version, foreign_key: { to_table: :coach_content_pack_versions }, index: { name: "idx_content_packs_current_version" }

    create_table :coach_content_pack_version_entries do |t|
      t.references :coach_content_pack_version, null: false, foreign_key: true
      t.references :coach_content_item_version, null: false, foreign_key: true
      t.integer :position, null: false
      t.timestamps
    end
    add_index :coach_content_pack_version_entries, [ :coach_content_pack_version_id, :position ], unique: true, name: "idx_pack_version_entries_position"
    add_index :coach_content_pack_version_entries, [ :coach_content_pack_version_id, :coach_content_item_version_id ], unique: true, name: "idx_pack_version_entries_item_version"
    add_check_constraint :coach_content_pack_version_entries, "position >= 0", name: "coach_content_pack_version_entries_position_nonnegative"

    create_table :coach_persona_draft_content_packs do |t|
      t.references :coach_persona, null: false, foreign_key: true
      t.references :coach_content_pack_version, null: false, foreign_key: true
      t.integer :position, null: false
      t.timestamps
    end
    add_index :coach_persona_draft_content_packs, [ :coach_persona_id, :position ], unique: true, name: "idx_persona_draft_packs_position"
    add_index :coach_persona_draft_content_packs, [ :coach_persona_id, :coach_content_pack_version_id ], unique: true, name: "idx_persona_draft_packs_version"

    create_table :coach_persona_version_content_packs do |t|
      t.references :coach_persona_version, null: false, foreign_key: true
      t.references :coach_content_pack_version, null: false, foreign_key: true
      t.integer :position, null: false
      t.timestamps
    end
    add_index :coach_persona_version_content_packs, [ :coach_persona_version_id, :position ], unique: true, name: "idx_persona_version_packs_position"
    add_index :coach_persona_version_content_packs, [ :coach_persona_version_id, :coach_content_pack_version_id ], unique: true, name: "idx_persona_version_packs_version"

    create_table :coach_content_citations do |t|
      t.references :chat_message, null: false, foreign_key: { on_delete: :cascade }
      t.references :coach_content_item_version, null: false, foreign_key: true
      t.references :coach_content_pack_version, null: false, foreign_key: true
      t.integer :rank, null: false
      t.string :reason, null: false
      t.timestamps
    end
    add_index :coach_content_citations, [ :chat_message_id, :rank ], unique: true, name: "idx_content_citations_message_rank"
    add_index :coach_content_citations, [ :chat_message_id, :coach_content_item_version_id ], unique: true, name: "idx_content_citations_message_item"
    add_check_constraint :coach_content_citations, "rank > 0 AND rank <= 6", name: "coach_content_citations_rank_valid"
  end
end
