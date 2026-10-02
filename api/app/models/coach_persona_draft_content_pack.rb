# frozen_string_literal: true

class CoachPersonaDraftContentPack < ApplicationRecord
  belongs_to :coach_persona, inverse_of: :draft_content_pack_links
  belongs_to :coach_content_pack_version
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_persona_id }
  validates :coach_content_pack_version_id, uniqueness: { scope: :coach_persona_id }
  validate :pack_is_platform_or_in_persona_workspace

  private

  def pack_is_platform_or_in_persona_workspace
    return if coach_persona.nil? || coach_content_pack_version.nil?

    pack = coach_content_pack_version.coach_content_pack
    return if pack.scope == "platform" || pack.coach_workspace_id == coach_persona.coach_workspace_id

    errors.add(:coach_content_pack_version, "must be platform content or belong to the persona workspace")
  end
end
