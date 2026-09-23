class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  MAX_USER_CONTENT_LENGTH = 2_000
  MAX_ASSISTANT_CONTENT_LENGTH = 8_000
  MAX_CONTENT_LENGTH = MAX_USER_CONTENT_LENGTH

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true
  validate :content_length_matches_role
  validate :attachments_are_safe_metadata

  def as_api_json(author: nil)
    {
      id: id,
      role: role,
      author: author || (role == "assistant" ? "Mia" : "You"),
      content: content,
      attachments: attachments,
      created_at: created_at&.iso8601
    }
  end

  private

  def content_length_matches_role
    maximum = role == "assistant" ? MAX_ASSISTANT_CONTENT_LENGTH : MAX_USER_CONTENT_LENGTH
    errors.add(:content, "is too long (maximum is #{maximum} characters)") if content.to_s.length > maximum
  end

  def attachments_are_safe_metadata
    return if attachments.is_a?(Array) && attachments.length <= 5

    errors.add(:attachments, "must be an array of up to 5 files")
  end
end
