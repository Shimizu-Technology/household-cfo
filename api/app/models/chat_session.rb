class ChatSession < ApplicationRecord
  belongs_to :household
  belongs_to :user

  has_many :chat_messages, dependent: :destroy

  def title_or_default
    title.presence || "Ask Mia"
  end
end
