# frozen_string_literal: true

class ValidateChatMessagePersonaConstraints < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :chat_messages, :coach_persona_versions
    validate_check_constraint :chat_messages, name: "chat_messages_persona_attribution_complete"
    validate_check_constraint :chat_messages, name: "chat_messages_assistant_author_length"
  end
end
