class CreateSavingsChatCards < ActiveRecord::Migration[8.1]
  def change
    create_table :savings_chat_cards do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :chat_message, null: false, foreign_key: true, index: { unique: true }
      t.string :kind, null: false
      t.jsonb :input, null: false, default: {}
      t.jsonb :state, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :savings_chat_cards, "kind IN ('daily_report', 'goal')", name: "savings_chat_card_kind"
    add_check_constraint :savings_chat_cards, "status IN ('pending', 'closed')", name: "savings_chat_card_status"
    add_index :savings_chat_cards, [ :savings_enrollment_id, :status, :id ], name: "savings_chat_cards_pending"
  end
end
