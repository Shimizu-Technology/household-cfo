# frozen_string_literal: true

class CohortRolloutParticipant < ApplicationRecord
  belongs_to :cohort_rollout, inverse_of: :participants
  belongs_to :cohort_rollout_wave, inverse_of: :participants
  belongs_to :coach_workspace
  belongs_to :cohort
  belongs_to :user, inverse_of: :cohort_rollout_participants

  validates :user_id, uniqueness: { scope: :cohort_rollout_id }
  validate :workspace_and_wave_boundaries
  validate :membership_epoch_boundary
  validate :participant_limit, on: :create
  validate :plan_still_building, on: :create
  validate :immutable_record, on: :update

  before_validation :copy_rollout_scope
  before_destroy :prevent_destroy

  private

  def copy_rollout_scope
    return unless cohort_rollout

    self.cohort_id ||= cohort_rollout.cohort_id
    self.coach_workspace_id ||= cohort_rollout.coach_workspace_id
  end

  def workspace_and_wave_boundaries
    if cohort_rollout &&
        (cohort_id != cohort_rollout.cohort_id || coach_workspace_id != cohort_rollout.coach_workspace_id)
      errors.add(:cohort_rollout, "must match the participant cohort and workspace")
    end
    return unless cohort_rollout_wave && cohort_rollout
    return if cohort_rollout_wave.cohort_rollout_id == cohort_rollout_id &&
      cohort_rollout_wave.cohort_id == cohort_id &&
      cohort_rollout_wave.coach_workspace_id == coach_workspace_id

    errors.add(:cohort_rollout_wave, "must belong to the participant rollout")
  end

  def participant_limit
    return unless cohort_rollout
    return if cohort_rollout.participants.where.not(id: id).count < CohortRollout::MAX_PARTICIPANTS

    errors.add(:base, "cohort rollout plans support at most #{CohortRollout::MAX_PARTICIPANTS} participants")
  end

  def membership_epoch_boundary
    runtime_rollout = cohort_rollout&.baseline_cohort_release_id.present?
    if runtime_rollout
      membership = cohort&.cohort_memberships&.find_by(id: cohort_membership_id, user_id: user_id, role: "participant")
      unless membership && membership.created_at == membership_started_at
        errors.add(:cohort_membership_id, "must pin the current participant membership epoch")
      end
    elsif cohort_membership_id.present? || membership_started_at.present?
      errors.add(:cohort_membership_id, "is available only for runtime rollouts")
    end
  end

  def plan_still_building
    return unless cohort_rollout&.transitions&.exists?

    errors.add(:base, "cannot append participants after rollout planning completes")
  end

  def immutable_record
    errors.add(:base, "cohort rollout participants are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort rollout participants cannot be deleted")
    throw :abort
  end
end
