# frozen_string_literal: true

class AddPresentationToChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :presentation, :jsonb, default: {}, null: false
    add_check_constraint :chat_messages,
      "jsonb_typeof(presentation) = 'object'",
      name: "chat_messages_presentation_object"
  end
end
