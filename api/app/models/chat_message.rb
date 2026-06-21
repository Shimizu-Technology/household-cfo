class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true

  def as_api_json(author: nil)
    {
      role: role,
      author: author || (role == "assistant" ? "Mia" : "You"),
      content: content
    }
  end
end
