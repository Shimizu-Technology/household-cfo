# frozen_string_literal: true

class CohortRolloutTransition < ApplicationRecord
  EVENT_TYPES = %w[planned activated advanced paused resumed completed cancelled rolled_back].freeze
  ACTOR_ROLES = CohortRollout::ACTOR_ROLES

  belongs_to :cohort_rollout, inverse_of: :transitions
  belongs_to :coach_workspace
  belongs_to :cohort
  belongs_to :actor_user, class_name: "User", inverse_of: :cohort_rollout_transitions
  belongs_to :rollback_cohort_release, class_name: "CohortRelease", optional: true,
    inverse_of: :rollback_cohort_rollout_transitions
  has_one :coach_operation_execution, dependent: :restrict_with_exception,
    inverse_of: :cohort_rollout_transition
  has_many :cohort_release_exposures, dependent: :restrict_with_exception
  has_many :cohort_release_activation_events, dependent: :restrict_with_exception

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :actor_role_snapshot, inclusion: { in: ACTOR_ROLES }
  validates :from_status, inclusion: { in: CohortRollout::STATUSES }, allow_nil: true
  validates :to_status, inclusion: { in: CohortRollout::STATUSES }
  validates :from_wave_position, :to_wave_position,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: CohortRollout::MAX_WAVES
    }, allow_nil: true
  validates :occurred_at, presence: true
  validates :participant_runtime_changed, inclusion: { in: [ true, false ] }
  validates :readiness_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :workspace_boundaries
  validate :rollback_shape
  validate :rollback_release_predates_target
  validate :readiness_evidence_shape
  validate :legal_event_shape
  validate :planned_attribution
  validate :runtime_change_shape
  validate :immutable_record, on: :update

  before_validation :copy_rollout_scope
  before_destroy :prevent_destroy

  private

  def copy_rollout_scope
    return unless cohort_rollout

    self.cohort_id ||= cohort_rollout.cohort_id
    self.coach_workspace_id ||= cohort_rollout.coach_workspace_id
  end

  def workspace_boundaries
    if cohort_rollout &&
        (cohort_id != cohort_rollout.cohort_id || coach_workspace_id != cohort_rollout.coach_workspace_id)
      errors.add(:cohort_rollout, "must match the transition cohort and workspace")
    end
    return unless rollback_cohort_release
    return if rollback_cohort_release.cohort_id == cohort_id &&
      rollback_cohort_release.coach_workspace_id == coach_workspace_id

    errors.add(:rollback_cohort_release, "must belong to the transition cohort and workspace")
  end

  def rollback_shape
    if event_type == "rolled_back"
      errors.add(:rollback_cohort_release, "is required for rollback") unless rollback_cohort_release
    elsif rollback_cohort_release
      errors.add(:rollback_cohort_release, "is only allowed for rollback")
    end
  end

  def rollback_release_predates_target
    return unless rollback_cohort_release && cohort_rollout&.target_cohort_release
    return if rollback_cohort_release.release_number < cohort_rollout.target_cohort_release.release_number

    errors.add(:rollback_cohort_release, "must predate the rollout target release")
  end

  def readiness_evidence_shape
    if event_type.in?(%w[activated advanced completed])
      errors.add(:readiness_digest, "is required for a wave transition") unless readiness_digest.present?
    elsif readiness_digest.present?
      errors.add(:readiness_digest, "is only allowed for a wave transition")
    end
  end

  def legal_event_shape
    valid = case event_type
    when "planned"
      from_status.nil? && to_status == "planned" && from_wave_position.nil? && to_wave_position == 0
    when "activated"
      from_status == "planned" && to_status == "active" && from_wave_position == 0 && to_wave_position == 1
    when "advanced"
      from_status == "active" && to_status == "active" && from_wave_position.to_i >= 1 &&
        to_wave_position == from_wave_position.to_i + 1
    when "completed"
      from_status == "active" && to_status == "completed" && positive_unchanged_wave?
    when "paused"
      from_status == "active" && to_status == "paused" && positive_unchanged_wave?
    when "resumed"
      from_status == "paused" && to_status == "active" && positive_unchanged_wave?
    when "cancelled"
      from_status == "planned" && to_status == "cancelled" && from_wave_position == 0 && to_wave_position == 0
    when "rolled_back"
      from_status.in?(%w[active paused]) && to_status == "rolled_back" && positive_unchanged_wave?
    else
      false
    end
    errors.add(:base, "rollout transition does not match the legal event shape") unless valid
  end

  def planned_attribution
    return unless event_type == "planned" && cohort_rollout

    if actor_user_id != cohort_rollout.planned_by_user_id
      errors.add(:actor_user, "must match the rollout planner")
    end
    unless actor_role_snapshot == cohort_rollout.planned_by_role_snapshot
      errors.add(:actor_role_snapshot, "must match the rollout planner role")
    end
  end

  def runtime_change_shape
    expected = cohort_rollout&.baseline_cohort_release_id.present? &&
      event_type.in?(%w[activated advanced completed rolled_back])
    return if participant_runtime_changed == expected

    errors.add(:participant_runtime_changed, "must match whether this rollout event changes participant runtime")
  end

  def positive_unchanged_wave?
    from_wave_position.to_i >= 1 && to_wave_position == from_wave_position
  end

  def immutable_record
    errors.add(:base, "cohort rollout transitions are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort rollout transitions cannot be deleted")
    throw :abort
  end
end
