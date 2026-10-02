# frozen_string_literal: true

class CoachPersonaVersionPhraseArtifact < ApplicationRecord
  belongs_to :coach_persona_version, inverse_of: :phrase_artifact_links
  belongs_to :coach_persona_phrase_promotion, inverse_of: :version_phrase_artifacts

  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :coach_persona_version_id }
  validates :artifact_id, uniqueness: { scope: :coach_persona_version_id }
  validates :artifact_fingerprint, :promotion_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :parent_version_is_under_construction, on: :create
  validate :snapshot_matches_promotion
  validate :published_link_is_immutable, on: :update
  before_destroy :prevent_destroy

  def integrity_valid?
    promotion = coach_persona_phrase_promotion
    promotion&.integrity_valid? && promotion.coach_persona_id == coach_persona_version&.coach_persona_id &&
      artifact_id.to_s == promotion.artifact_id.to_s && artifact_fingerprint == promotion.artifact_fingerprint &&
      promotion_digest == promotion.promotion_digest
  end

  private

  def parent_version_is_under_construction
    errors.add(:base, "sealed persona versions cannot accept phrase artifacts") if coach_persona_version&.sealed?
  end

  def snapshot_matches_promotion
    errors.add(:base, "version phrase artifact does not match its promotion") unless integrity_valid?
  end

  def published_link_is_immutable
    errors.add(:base, "published phrase artifact links are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "published phrase artifact links cannot be deleted")
    throw :abort
  end
end
