class CreateHouseholdMemories < ActiveRecord::Migration[8.0]
  def change
    create_table :household_memories do |t|
      t.references :household, null: false, foreign_key: true
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.references :source_chat_message, null: true, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.string :category, null: false
      t.string :status, null: false, default: "pending_confirmation"
      t.string :sensitivity, null: false, default: "ordinary"
      t.string :visibility, null: false, default: "private"
      t.string :source_kind, null: false, default: "manual_profile"
      t.string :request_key
      t.string :display_value, null: false
      t.jsonb :structured_value, null: false, default: {}
      t.datetime :confirmed_at
      t.datetime :rejected_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :household_memories, %i[household_id status expires_at], name: "index_household_memories_on_active_scope"
    add_index :household_memories, %i[household_id owner_user_id request_key], unique: true,
      where: "request_key IS NOT NULL", name: "index_household_memories_on_request_key"
    add_check_constraint :household_memories,
      "category IN ('goal', 'preference', 'constraint', 'habit', 'coaching_style', 'follow_up')",
      name: "household_memories_category_valid"
    add_check_constraint :household_memories,
      "status IN ('pending_confirmation', 'user_confirmed', 'rejected', 'expired')",
      name: "household_memories_status_valid"
    add_check_constraint :household_memories,
      "sensitivity IN ('ordinary', 'sensitive')",
      name: "household_memories_sensitivity_valid"
    add_check_constraint :household_memories,
      "visibility = 'private'",
      name: "household_memories_visibility_valid"
    add_check_constraint :household_memories,
      "source_kind IN ('manual_profile', 'mia_command')",
      name: "household_memories_source_kind_valid"
    add_check_constraint :household_memories,
      "char_length(display_value) BETWEEN 1 AND 500",
      name: "household_memories_display_value_length"
    add_check_constraint :household_memories,
      "request_key IS NULL OR char_length(request_key) <= 120",
      name: "household_memories_request_key_length"
  end
end
