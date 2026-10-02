# frozen_string_literal: true

class CoachPersonaVersionContentPack < ApplicationRecord
  belongs_to :coach_persona_version, inverse_of: :content_pack_links
  belongs_to :coach_content_pack_version
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_persona_version_id }
  validates :coach_content_pack_version_id, uniqueness: { scope: :coach_persona_version_id }
  validate :pack_is_platform_or_in_persona_workspace
  validate :parent_version_is_under_construction, on: :create
  validate :published_link_is_immutable, on: :update
  before_destroy :prevent_destroy

  private

  def parent_version_is_under_construction
    errors.add(:base, "sealed persona versions cannot accept content packs") if coach_persona_version&.sealed?
  end

  def pack_is_platform_or_in_persona_workspace
    return if coach_persona_version.nil? || coach_content_pack_version.nil?

    pack = coach_content_pack_version.coach_content_pack
    workspace_id = coach_persona_version.coach_persona.coach_workspace_id
    return if pack.scope == "platform" || pack.coach_workspace_id == workspace_id

    errors.add(:coach_content_pack_version, "must be platform content or belong to the persona workspace")
  end

  def published_link_is_immutable
    errors.add(:base, "published persona content links are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published persona content links cannot be deleted")
    throw :abort
  end
end
