# frozen_string_literal: true

class CohortRollout < ApplicationRecord
  STATUSES = %w[planned active paused completed cancelled rolled_back].freeze
  OPEN_STATUSES = %w[planned active paused].freeze
  ACTOR_ROLES = %w[platform_admin owner reviewer].freeze
  MAX_WAVES = 25
  MAX_PARTICIPANTS = 500

  belongs_to :coach_workspace
  belongs_to :cohort, inverse_of: :cohort_rollouts
  belongs_to :target_cohort_release, class_name: "CohortRelease", inverse_of: :targeted_cohort_rollouts
  belongs_to :rollback_cohort_release, class_name: "CohortRelease", optional: true,
    inverse_of: :rollback_cohort_rollouts
  belongs_to :planned_by_user, class_name: "User", inverse_of: :planned_cohort_rollouts

  has_many :waves, -> { order(:position, :id) }, class_name: "CohortRolloutWave",
    dependent: :restrict_with_exception, inverse_of: :cohort_rollout
  has_many :participants, class_name: "CohortRolloutParticipant",
    dependent: :restrict_with_exception, inverse_of: :cohort_rollout
  has_many :transitions, -> { order(:id) }, class_name: "CohortRolloutTransition",
    dependent: :restrict_with_exception, inverse_of: :cohort_rollout

  validates :status, inclusion: { in: STATUSES }
  validates :planned_by_role_snapshot, inclusion: { in: ACTOR_ROLES }
  validates :planned_at, presence: true
  validates :cohort_id, uniqueness: {
    conditions: -> { where(status: OPEN_STATUSES) },
    message: "already has an open rollout plan"
  }, if: -> { status.in?(OPEN_STATUSES) }
  validates :current_wave_position,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_WAVES }
  validate :workspace_boundaries
  validate :rollback_shape
  validate :rollback_release_predates_target
  validate :current_wave_exists
  validate :lifecycle_timestamp_shape
  validate :plan_identity_is_immutable, on: :update

  before_destroy :prevent_destroy

  private

  def workspace_boundaries
    errors.add(:coach_workspace, "must match the cohort") if cohort && cohort.coach_workspace_id != coach_workspace_id

    [ [ :target_cohort_release, target_cohort_release ],
      [ :rollback_cohort_release, rollback_cohort_release ] ].each do |attribute, release|
      next unless release
      next if release.cohort_id == cohort_id && release.coach_workspace_id == coach_workspace_id

      errors.add(attribute, "must belong to the rollout cohort and workspace")
    end
  end

  def rollback_shape
    if status == "rolled_back"
      errors.add(:rollback_cohort_release, "is required after rollback") unless rollback_cohort_release
      errors.add(:rolled_back_at, "is required after rollback") unless rolled_back_at
    elsif rollback_cohort_release || rolled_back_at
      errors.add(:rollback_cohort_release, "is only allowed after rollback")
    end
  end

  def rollback_release_predates_target
    return unless rollback_cohort_release && target_cohort_release
    return if rollback_cohort_release.release_number < target_cohort_release.release_number

    errors.add(:rollback_cohort_release, "must predate the target release")
  end

  def current_wave_exists
    return if current_wave_position.to_i.zero?

    highest_position = waves.loaded? ? waves.map(&:position).compact.max : waves.maximum(:position)
    errors.add(:current_wave_position, "must reference a planned wave") if highest_position.to_i < current_wave_position
  end

  def lifecycle_timestamp_shape
    required, forbidden = case status
    when "planned"
      [ [], %i[activated_at paused_at completed_at cancelled_at rolled_back_at] ]
    when "active"
      [ %i[activated_at], %i[paused_at completed_at cancelled_at rolled_back_at] ]
    when "paused"
      [ %i[activated_at paused_at], %i[completed_at cancelled_at rolled_back_at] ]
    when "completed"
      [ %i[activated_at completed_at], %i[paused_at cancelled_at rolled_back_at] ]
    when "cancelled"
      [ %i[cancelled_at], %i[activated_at paused_at completed_at rolled_back_at] ]
    when "rolled_back"
      [ %i[activated_at rolled_back_at], %i[completed_at cancelled_at] ]
    else
      return
    end
    required.each { |attribute| errors.add(attribute, "is required for #{status}") if public_send(attribute).nil? }
    forbidden.each { |attribute| errors.add(attribute, "must be blank for #{status}") if public_send(attribute).present? }
  end

  def plan_identity_is_immutable
    fields = %w[
      coach_workspace_id cohort_id target_cohort_release_id planned_by_user_id
      planned_by_role_snapshot planned_at created_at
    ]
    errors.add(:base, "cohort rollout plan identity is immutable") if changes_to_save.keys.intersect?(fields)
  end

  def prevent_destroy
    errors.add(:base, "cohort rollouts cannot be deleted")
    throw :abort
  end
end
