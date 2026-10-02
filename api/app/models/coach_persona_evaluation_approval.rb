# frozen_string_literal: true

require "digest"
require "json"

class CoachPersonaEvaluationApproval < ApplicationRecord
  DECISIONS = %w[approved rejected].freeze

  belongs_to :evaluation_run, class_name: "CoachPersonaEvaluationRun",
    foreign_key: :coach_persona_evaluation_run_id
  belongs_to :reviewed_by_user, class_name: "User"
  has_many :persona_versions, class_name: "CoachPersonaVersion", dependent: :restrict_with_exception

  validates :decision, inclusion: { in: DECISIONS }
  validates :run_digest, :approval_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :reviewed_at, presence: true
  validates :reviewer_role_snapshot, presence: true, on: :create
  validates :reviewer_authority_digest, format: { with: /\A[0-9a-f]{64}\z/ }, on: :create
  validate :run_snapshot_matches
  validate :reviewer_is_authorized
  validate :digest_matches_snapshot
  validate :immutable_record, on: :update
  before_destroy :prevent_destroy

  def self.digest_for(run:, reviewer_id:, decision:, self_review:, reviewed_at:, reviewer_authority_snapshot: nil,
    reviewer_authority_digest: nil)
    payload = {
      run_id: run.id,
      run_digest: run.run_digest,
      reviewer_id: reviewer_id,
      decision: decision,
      self_review: self_review == true,
      reviewed_at: reviewed_at.in_time_zone("UTC").iso8601(6)
    }
    if reviewer_authority_snapshot.present?
      payload[:reviewer_authority_snapshot] = reviewer_authority_snapshot
      payload[:reviewer_authority_digest] = reviewer_authority_digest
    end
    Digest::SHA256.hexdigest(JSON.generate(Mia::PhraseManifest.canonicalize(payload)).b)
  end

  def integrity_valid?
    evaluation_run&.passed_and_valid? && run_digest == evaluation_run.run_digest &&
      approval_digest.present? && ActiveSupport::SecurityUtils.secure_compare(approval_digest, expected_digest)
  end

  private

  def expected_digest
    self.class.digest_for(
      run: evaluation_run,
      reviewer_id: reviewed_by_user_id,
      decision: decision,
      self_review: self_review,
      reviewed_at: reviewed_at,
      reviewer_authority_snapshot: reviewer_authority_snapshot,
      reviewer_authority_digest: reviewer_authority_digest
    )
  end

  def run_snapshot_matches
    errors.add(:base, "approval must reference an intact passed run") unless evaluation_run&.passed_and_valid? && run_digest == evaluation_run.run_digest
  end

  def reviewer_is_authorized
    workspace = evaluation_run&.release_candidate&.coach_persona&.coach_workspace
    unless workspace&.allows?(reviewed_by_user, :review)
      errors.add(:reviewed_by_user, "must be able to review the persona workspace")
      return
    end
    expected_self_review = evaluation_run.requested_by_user_id == reviewed_by_user_id
    errors.add(:self_review, "must match the evaluation requester") unless self_review == expected_self_review
    return unless self_review

    membership = workspace.membership_for(reviewed_by_user)
    owners = workspace.coach_workspace_memberships.where(role: "owner").count
    errors.add(:self_review, "is allowed only for the sole workspace owner") unless membership&.role == "owner" && owners == 1
  end

  def digest_matches_snapshot
    errors.add(:approval_digest, "must match the approval") unless approval_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(approval_digest, expected_digest)
  end

  def authority_snapshot_valid?
    Mia::PersonaRelease::ReviewAuthority.valid?(reviewer_authority_snapshot, reviewer_authority_digest) &&
      reviewer_role_snapshot == reviewer_authority_snapshot["role"]
  end
  public :authority_snapshot_valid?

  def immutable_record
    errors.add(:base, "evaluation approvals are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "evaluation approvals cannot be deleted")
    throw :abort
  end
end
