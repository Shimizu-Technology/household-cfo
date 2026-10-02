# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaPhrasePromotion < ApplicationRecord
  belongs_to :coach_persona
  belongs_to :coach_phrase_proposal
  belongs_to :coach_phrase_attestation
  belongs_to :promoted_by_user, class_name: "User"
  has_many :version_phrase_artifacts, class_name: "CoachPersonaVersionPhraseArtifact", dependent: :restrict_with_exception

  validates :artifact_id, presence: true
  validates :artifact_fingerprint, :promotion_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :promoted_at, presence: true
  validate :linked_records_match
  validate :artifact_is_exact
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(persona_id:, proposal:, attestation:, artifact:, promoted_by_user_id:, promoted_at:)
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      persona_id: persona_id,
      proposal_id: proposal.id,
      proposal_digest: proposal.proposal_digest,
      attestation_id: attestation.id,
      attestation_digest: attestation.attestation_digest,
      artifact: artifact,
      promoted_by_user_id: promoted_by_user_id,
      promoted_at: promoted_at.in_time_zone("UTC").iso8601(6)
    })).b)
  end

  def integrity_valid?
    errors.clear
    linked_records_match
    artifact_is_exact
    digest_matches_snapshot
    errors.empty? && coach_phrase_attestation.integrity_valid?
  end

  private

  def linked_records_match
    return unless coach_persona && coach_phrase_proposal && coach_phrase_attestation

    valid = coach_phrase_proposal.coach_workspace_id == coach_persona.coach_workspace_id &&
      coach_phrase_attestation.coach_phrase_proposal_id == coach_phrase_proposal_id &&
      coach_phrase_attestation.decision == "approved"
    errors.add(:base, "phrase promotion review chain is invalid") unless valid
  end

  def artifact_is_exact
    normalized = Mia::PersonaSchema.normalize(artifact)
    errors.add(:artifact, "must be an approved-source phrase artifact") unless normalized["provenance"] == "approved_source"
    errors.add(:artifact_id, "must match the artifact") unless normalized["artifact_id"] == artifact_id.to_s
    expected = Mia::PersonaSchema.artifact_fingerprint(normalized)
    unless artifact_fingerprint == normalized["fingerprint"] && ActiveSupport::SecurityUtils.secure_compare(artifact_fingerprint.to_s, expected)
      errors.add(:artifact_fingerprint, "must match the exact artifact")
    end
    unless CoachPhraseProposal::PAYLOAD_KEYS.all? { |key| normalized[key] == coach_phrase_proposal.phrase_payload[key] }
      errors.add(:artifact, "must preserve the attested phrase")
    end
  end

  def digest_matches_snapshot
    return unless coach_persona && coach_phrase_proposal && coach_phrase_attestation && promoted_at

    expected = self.class.digest_for(
      persona_id: coach_persona_id,
      proposal: coach_phrase_proposal,
      attestation: coach_phrase_attestation,
      artifact: artifact,
      promoted_by_user_id: promoted_by_user_id,
      promoted_at: promoted_at
    )
    errors.add(:promotion_digest, "must match the promotion") unless promotion_digest.present? && ActiveSupport::SecurityUtils.secure_compare(promotion_digest, expected)
  end

  def immutable_record
    errors.add(:base, "phrase promotions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "phrase promotions cannot be deleted")
    throw :abort
  end
end
