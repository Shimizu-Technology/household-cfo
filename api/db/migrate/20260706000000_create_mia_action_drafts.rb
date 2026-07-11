class CreateMiaActionDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :mia_action_drafts do |t|
      t.references :household, null: false, foreign_key: true
      t.references :requested_by_user, null: false, foreign_key: { to_table: :users }
      t.references :source_chat_message, foreign_key: { to_table: :chat_messages }
      t.references :assistant_chat_message, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :draft_type, null: false, default: "budget_edit"
      t.integer :year, null: false
      t.string :title, null: false
      t.text :summary, null: false
      t.text :rationale
      t.text :source_prompt
      t.datetime :applied_at
      t.references :applied_by_user, foreign_key: { to_table: :users }
      t.datetime :canceled_at
      t.references :canceled_by_user, foreign_key: { to_table: :users }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :household_id, :status, :year, :created_at ], name: "index_mia_action_drafts_on_household_status_year_created"
      t.check_constraint "status IN ('pending', 'applied', 'canceled')", name: "mia_action_drafts_status_valid"
      t.check_constraint "draft_type IN ('budget_edit')", name: "mia_action_drafts_type_valid"
      t.check_constraint "year >= 2000 AND year <= 2100", name: "mia_action_drafts_year_reasonable"
    end

    create_table :mia_action_items do |t|
      t.references :mia_action_draft, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :action_type, null: false
      t.string :target_record_type
      t.bigint :target_record_id
      t.string :label, null: false
      t.text :description
      t.jsonb :payload, null: false, default: {}
      t.jsonb :before_snapshot, null: false, default: {}
      t.jsonb :after_snapshot, null: false, default: {}
      t.timestamps

      t.index [ :mia_action_draft_id, :position ], name: "index_mia_action_items_on_draft_position"
      t.index [ :target_record_type, :target_record_id ], name: "index_mia_action_items_on_target"
      t.check_constraint "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category')", name: "mia_action_items_action_type_valid"
      t.check_constraint "position >= 0", name: "mia_action_items_position_non_negative"
    end

    create_table :household_audit_events do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :actor_type, null: false, default: "user"
      t.string :event_type, null: false
      t.string :auditable_type
      t.bigint :auditable_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps

      t.index [ :household_id, :occurred_at ], name: "index_household_audit_events_on_household_occurred_at"
      t.index [ :auditable_type, :auditable_id ], name: "index_household_audit_events_on_auditable"
      t.check_constraint "actor_type IN ('user', 'mia', 'system')", name: "household_audit_events_actor_type_valid"
    end
  end
end
