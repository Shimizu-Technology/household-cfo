# frozen_string_literal: true

require "digest"
require "json"

class CoachPhraseAttestation < ApplicationRecord
  DECISIONS = %w[approved rejected].freeze

  belongs_to :coach_phrase_proposal, inverse_of: :attestation
  belongs_to :reviewed_by_user, class_name: "User"
  has_many :persona_promotions, class_name: "CoachPersonaPhrasePromotion", dependent: :restrict_with_exception

  validates :decision, inclusion: { in: DECISIONS }
  validates :reviewed_at, presence: true
  validates :proposal_digest, :evidence_digest, :attestation_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :digest_matches_snapshot
  validate :proposal_snapshot_matches
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(proposal:, reviewer_id:, decision:, self_review:, reviewed_at:)
    Digest::SHA256.hexdigest(JSON.generate({
      proposal_id: proposal.id,
      proposal_digest: proposal.proposal_digest,
      evidence_digest: proposal.evidence_digest,
      reviewer_id: reviewer_id,
      decision: decision,
      self_review: self_review == true,
      reviewed_at: reviewed_at.in_time_zone("UTC").iso8601(6)
    }).b)
  end

  def integrity_valid?
    proposal_snapshot_matches? && attestation_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(attestation_digest, expected_digest)
  end

  private

  def expected_digest
    self.class.digest_for(
      proposal: coach_phrase_proposal,
      reviewer_id: reviewed_by_user_id,
      decision: decision,
      self_review: self_review,
      reviewed_at: reviewed_at
    )
  end

  def proposal_snapshot_matches?
    proposal = coach_phrase_proposal
    proposal&.integrity_valid? && proposal_digest == proposal.proposal_digest && evidence_digest == proposal.evidence_digest
  end

  def digest_matches_snapshot
    errors.add(:attestation_digest, "must match the attestation") unless attestation_digest.present? && ActiveSupport::SecurityUtils.secure_compare(attestation_digest, expected_digest)
  end

  def proposal_snapshot_matches
    errors.add(:base, "attestation does not match the submitted proposal") unless proposal_snapshot_matches?
  end

  def immutable_record
    errors.add(:base, "phrase attestations are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "phrase attestations cannot be deleted")
    throw :abort
  end
end
