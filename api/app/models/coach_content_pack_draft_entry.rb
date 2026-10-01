# frozen_string_literal: true

class CoachContentPackDraftEntry < ApplicationRecord
  belongs_to :coach_content_pack, inverse_of: :draft_entries
  belongs_to :coach_content_item_version, inverse_of: :draft_pack_entries
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_content_pack_id }
  validates :coach_content_item_version_id, uniqueness: { scope: :coach_content_pack_id }
end
