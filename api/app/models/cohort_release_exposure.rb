# frozen_string_literal: true

class CohortReleaseExposure < ApplicationRecord
  EVENT_TYPES = %w[wave rollback].freeze

  belongs_to :coach_workspace
  belongs_to :cohort
  belongs_to :user
  belongs_to :cohort_release
  belongs_to :cohort_rollout
  belongs_to :cohort_rollout_wave
  belongs_to :cohort_rollout_transition

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :exposure_key, presence: true, length: { maximum: 160 }, uniqueness: { scope: :cohort_id }
  validates :membership_started_at, :occurred_at, presence: true
  validate :tenant_boundaries
  validate :membership_epoch_was_participant, on: :create
  validate :immutable_record, on: :update

  before_destroy :prevent_destroy

  private

  def tenant_boundaries
    records = [ cohort_release, cohort_rollout, cohort_rollout_wave, cohort_rollout_transition ].compact
    unless cohort&.coach_workspace_id == coach_workspace_id && records.all? do |record|
      record.cohort_id == cohort_id && record.coach_workspace_id == coach_workspace_id
    end
      errors.add(:base, "runtime exposure records must stay inside one cohort and workspace")
    end
    return unless cohort_rollout_wave && cohort_rollout_transition
    return if cohort_rollout_wave.cohort_rollout_id == cohort_rollout_id &&
      cohort_rollout_transition.cohort_rollout_id == cohort_rollout_id

    errors.add(:base, "runtime exposure wave and transition must belong to the rollout")
  end

  def membership_epoch_was_participant
    membership = CohortMembership.find_by(id: cohort_membership_id, cohort_id: cohort_id, user_id: user_id, role: "participant")
    return if membership && membership.created_at == membership_started_at

    errors.add(:cohort_membership_id, "must identify the participant membership epoch")
  end

  def immutable_record
    errors.add(:base, "cohort release exposures are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort release exposures cannot be deleted")
    throw :abort
  end
end
