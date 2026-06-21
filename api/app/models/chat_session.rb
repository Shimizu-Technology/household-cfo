class ChatSession < ApplicationRecord
  belongs_to :household
  belongs_to :user

  has_many :chat_messages, dependent: :destroy

  validates :user_id, uniqueness: { scope: :household_id }

  def title_or_default
    title.presence || "Ask Mia"
  end
end
