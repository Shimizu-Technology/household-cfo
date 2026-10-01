# frozen_string_literal: true

class CoachContentPackVersionEntry < ApplicationRecord
  belongs_to :coach_content_pack_version, inverse_of: :entries
  belongs_to :coach_content_item_version, inverse_of: :pack_version_entries
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_content_pack_version_id }
  validates :coach_content_item_version_id, uniqueness: { scope: :coach_content_pack_version_id }
  validate :published_entry_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def published_entry_is_immutable
    errors.add(:base, "published pack entries are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published pack entries cannot be deleted")
    throw :abort
  end
end
