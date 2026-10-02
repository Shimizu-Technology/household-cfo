# frozen_string_literal: true

require "digest"
require "json"

class CoachPhraseAudienceAttestation < ApplicationRecord
  DECISIONS = %w[approved rejected].freeze

  belongs_to :release_candidate, class_name: "CoachPersonaReleaseCandidate",
    foreign_key: :coach_persona_release_candidate_id
  belongs_to :reviewed_by_user, class_name: "User"

  validates :artifact_id, presence: true
  validates :artifact_fingerprint, :audience_digest, :attestation_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :decision, inclusion: { in: DECISIONS }
  validates :reviewed_at, presence: true
  validate :artifact_matches_candidate
  validate :reviewer_is_authorized
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(candidate:, artifact_id:, artifact_fingerprint:, reviewer_id:, decision:, self_review:, reviewed_at:)
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize({
      candidate_id: candidate.id,
      candidate_digest: candidate.manifest_digest,
      artifact_id: artifact_id.to_s,
      artifact_fingerprint: artifact_fingerprint,
      audience_digest: candidate.audience_digest,
      reviewer_id: reviewer_id,
      decision: decision,
      self_review: self_review == true,
      reviewed_at: reviewed_at.in_time_zone("UTC").iso8601(6)
    })).b)
  end

  def integrity_valid?
    release_candidate&.integrity_valid? && artifact_matches_candidate? &&
      attestation_digest.present? && ActiveSupport::SecurityUtils.secure_compare(attestation_digest, expected_digest)
  end

  private

  def artifact
    Array(release_candidate&.phrase_artifacts_snapshot).find { |entry| entry["artifact_id"].to_s == artifact_id.to_s }
  end

  def artifact_matches_candidate?
    artifact.present? && artifact["fingerprint"] == artifact_fingerprint && audience_digest == release_candidate.audience_digest
  end

  def artifact_matches_candidate
    errors.add(:base, "phrase audience attestation does not match the release candidate") unless artifact_matches_candidate?
  end

  def reviewer_is_authorized
    workspace = release_candidate&.coach_persona&.coach_workspace
    unless workspace&.allows?(reviewed_by_user, :review)
      errors.add(:reviewed_by_user, "must be able to review the persona workspace")
      return
    end
    expected_self_review = artifact && artifact["source_user_id"].to_i == reviewed_by_user_id
    errors.add(:self_review, "must match the phrase author") unless self_review == expected_self_review
    return unless self_review

    membership = workspace.membership_for(reviewed_by_user)
    owners = workspace.coach_workspace_memberships.where(role: "owner").count
    errors.add(:self_review, "is allowed only for the sole workspace owner") unless membership&.role == "owner" && owners == 1
  end

  def expected_digest
    self.class.digest_for(
      candidate: release_candidate,
      artifact_id: artifact_id,
      artifact_fingerprint: artifact_fingerprint,
      reviewer_id: reviewed_by_user_id,
      decision: decision,
      self_review: self_review,
      reviewed_at: reviewed_at
    )
  end

  def digest_matches_snapshot
    errors.add(:attestation_digest, "must match the attestation") unless attestation_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(attestation_digest, expected_digest)
  end

  def immutable_record
    errors.add(:base, "phrase audience attestations are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "phrase audience attestations cannot be deleted")
    throw :abort
  end
end
