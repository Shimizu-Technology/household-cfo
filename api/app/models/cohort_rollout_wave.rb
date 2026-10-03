# frozen_string_literal: true

class CohortRolloutWave < ApplicationRecord
  belongs_to :cohort_rollout, inverse_of: :waves
  belongs_to :coach_workspace
  belongs_to :cohort

  has_many :participants, class_name: "CohortRolloutParticipant",
    dependent: :restrict_with_exception, inverse_of: :cohort_rollout_wave
  has_many :cohort_release_exposures, dependent: :restrict_with_exception

  normalizes :name, with: ->(value) { value.to_s.squish }

  validates :position, numericality: {
    only_integer: true,
    greater_than: 0,
    less_than_or_equal_to: CohortRollout::MAX_WAVES
  }, uniqueness: { scope: :cohort_rollout_id }
  validates :name, presence: true, length: { maximum: 80 }
  validate :workspace_boundaries
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

  def workspace_boundaries
    return unless cohort_rollout

    unless cohort_id == cohort_rollout.cohort_id && coach_workspace_id == cohort_rollout.coach_workspace_id
      errors.add(:cohort_rollout, "must match the wave cohort and workspace")
    end
  end

  def plan_still_building
    return unless cohort_rollout&.transitions&.exists?

    errors.add(:base, "cannot append waves after rollout planning completes")
  end

  def immutable_record
    errors.add(:base, "cohort rollout waves are immutable") if has_changes_to_save?
  end

  def prevent_destroy
    errors.add(:base, "cohort rollout waves cannot be deleted")
    throw :abort
  end
end
