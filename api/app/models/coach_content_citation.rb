# frozen_string_literal: true

class CoachContentCitation < ApplicationRecord
  belongs_to :chat_message
  belongs_to :coach_content_item_version
  belongs_to :coach_content_pack_version
  validates :rank, numericality: { only_integer: true, in: 1..6 }, uniqueness: { scope: :chat_message_id }
  validates :coach_content_item_version_id, uniqueness: { scope: :chat_message_id }
  validates :reason, presence: true, length: { maximum: 240 }
  validate :item_version_belongs_to_pack_version

  private

  def item_version_belongs_to_pack_version
    return if coach_content_item_version.nil? || coach_content_pack_version.nil?
    return if coach_content_pack_version.entries.where(coach_content_item_version_id: coach_content_item_version_id).exists?

    errors.add(:coach_content_item_version, "must belong to the cited content pack version")
  end
end
