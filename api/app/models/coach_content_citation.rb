# frozen_string_literal: true

class CoachContentCitation < ApplicationRecord
  belongs_to :chat_message
  belongs_to :coach_content_item_version
  belongs_to :coach_content_pack_version
  validates :rank, numericality: { only_integer: true, in: 1..6 }, uniqueness: { scope: :chat_message_id }
  validates :coach_content_item_version_id, uniqueness: { scope: :chat_message_id }
  validates :reason, presence: true, length: { maximum: 240 }
end
