class AllowLongerMiaResponses < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :chat_messages, name: "chat_messages_content_length"
    add_check_constraint :chat_messages,
      "(role = 'user' AND char_length(content) <= 2000) OR (role = 'assistant' AND char_length(content) <= 8000)",
      name: "chat_messages_content_length_by_role"
  end

  def down
    remove_check_constraint :chat_messages, name: "chat_messages_content_length_by_role"
    add_check_constraint :chat_messages, "char_length(content) <= 2000", name: "chat_messages_content_length"
  end
end
