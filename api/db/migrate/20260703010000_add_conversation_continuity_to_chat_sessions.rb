class AddConversationContinuityToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :rolling_summary, :text
    add_column :chat_sessions, :open_topics, :jsonb, null: false, default: []
    add_column :chat_sessions, :active_topic, :jsonb, null: false, default: {}
    add_column :chat_sessions, :last_compacted_message_id, :bigint
    add_column :chat_sessions, :last_compacted_at, :datetime

    add_index :chat_sessions, :last_compacted_message_id
  end
end
