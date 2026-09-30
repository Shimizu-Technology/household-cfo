class ExpandMiaUserMessageLength < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :chat_messages, name: "chat_messages_content_length_by_role"
    add_check_constraint :chat_messages,
      "role IN ('user', 'assistant') AND char_length(content) <= 8000",
      name: "chat_messages_content_length_by_role"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Chat messages may contain participant content above 2,000 characters; shrinking the constraint could reject existing data."
  end
end
