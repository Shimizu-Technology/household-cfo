# frozen_string_literal: true

class CoachPersonaVersionContentPack < ApplicationRecord
  belongs_to :coach_persona_version, inverse_of: :content_pack_links
  belongs_to :coach_content_pack_version
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_persona_version_id }
  validates :coach_content_pack_version_id, uniqueness: { scope: :coach_persona_version_id }
  validate :pack_is_platform_or_owned_by_persona_creator
  validate :published_link_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def pack_is_platform_or_owned_by_persona_creator
    return if coach_persona_version.nil? || coach_content_pack_version.nil?

    pack = coach_content_pack_version.coach_content_pack
    owner_id = coach_persona_version.coach_persona.created_by_user_id
    return if pack.scope == "platform" || pack.created_by_user_id == owner_id

    errors.add(:coach_content_pack_version, "must be platform content or owned by the persona creator")
  end

  def published_link_is_immutable
    errors.add(:base, "published persona content links are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published persona content links cannot be deleted")
    throw :abort
  end
end
