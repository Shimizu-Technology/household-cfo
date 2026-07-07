class AddAttachmentsToChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :attachments, :jsonb, null: false, default: []
  end
end
