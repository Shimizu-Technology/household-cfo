class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  MAX_CONTENT_LENGTH = 2_000

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }
  validate :attachments_are_safe_metadata

  def as_api_json(author: nil)
    {
      role: role,
      author: author || (role == "assistant" ? "Mia" : "You"),
      content: content,
      attachments: attachments
    }
  end

  private

  def attachments_are_safe_metadata
    return if attachments.is_a?(Array) && attachments.length <= 5

    errors.add(:attachments, "must be an array of up to 5 files")
  end
end
