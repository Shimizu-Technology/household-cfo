# frozen_string_literal: true

class CohortReleaseActivationEvent < ApplicationRecord
  EVENT_TYPES = %w[backfill initial_launch rollout_completed].freeze

  belongs_to :coach_workspace
  belongs_to :cohort
  belongs_to :from_cohort_release, class_name: "CohortRelease", optional: true
  belongs_to :to_cohort_release, class_name: "CohortRelease"
  belongs_to :cohort_rollout, optional: true
  belongs_to :cohort_rollout_transition, optional: true
  belongs_to :actor_user, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :request_key, presence: true, length: { maximum: 100 }, uniqueness: { scope: :cohort_id }
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :occurred_at, presence: true
  validate :tenant_boundaries
  validate :event_shape
  validate :immutable_record, on: :update

  before_destroy :prevent_destroy

  private

  def tenant_boundaries
    records = [ from_cohort_release, to_cohort_release, cohort_rollout, cohort_rollout_transition ].compact
    return if cohort&.coach_workspace_id == coach_workspace_id && records.all? do |record|
      record.cohort_id == cohort_id && record.coach_workspace_id == coach_workspace_id
    end

    errors.add(:base, "release activation evidence must stay inside one cohort and workspace")
  end

  def event_shape
    if event_type == "backfill"
      if cohort_rollout || cohort_rollout_transition || actor_user || actor_role_snapshot
        errors.add(:base, "backfill activation cannot claim a rollout or user actor")
      end
    elsif event_type == "initial_launch"
      if from_cohort_release || cohort_rollout || cohort_rollout_transition || actor_user.nil? ||
          !actor_role_snapshot.in?(CohortRollout::ACTOR_ROLES)
        errors.add(:base, "initial launch requires a user actor and no previous release or rollout")
      end
    elsif cohort_rollout.nil? || cohort_rollout_transition.nil? || actor_user.nil? ||
        !actor_role_snapshot.in?(CohortRollout::ACTOR_ROLES)
      errors.add(:base, "rollout activation requires rollout, transition, and actor evidence")
    elsif cohort_rollout_transition.cohort_rollout_id != cohort_rollout_id
      errors.add(:cohort_rollout_transition, "must belong to the activation rollout")
    end
  end

  def immutable_record
    errors.add(:base, "cohort release activation events are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort release activation events cannot be deleted")
    throw :abort
  end
end
