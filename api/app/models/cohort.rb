class Cohort < ApplicationRecord
  STATUSES = %w[draft enrolling active completed archived].freeze

  belongs_to :created_by_user, class_name: "User"
  belongs_to :coach_workspace
  belongs_to :active_cohort_release, class_name: "CohortRelease", optional: true,
    inverse_of: :active_for_cohorts

  has_many :cohort_memberships, dependent: :destroy
  has_many :users, through: :cohort_memberships
  has_one :cohort_persona_assignment, dependent: :destroy, inverse_of: :cohort
  has_one :coach_persona, through: :cohort_persona_assignment
  has_one :coach_persona_version, through: :cohort_persona_assignment
  has_one :cohort_experience_configuration, dependent: :restrict_with_exception, inverse_of: :cohort
  has_many :cohort_releases, dependent: :restrict_with_exception, inverse_of: :cohort
  has_many :coach_operation_executions, dependent: :restrict_with_exception, inverse_of: :cohort
  has_many :cohort_rollouts, dependent: :restrict_with_exception, inverse_of: :cohort
  has_many :cohort_release_exposures, dependent: :restrict_with_exception
  has_many :cohort_release_activation_events, dependent: :restrict_with_exception

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { case_sensitive: false, scope: :coach_workspace_id }
  validates :status, inclusion: { in: STATUSES }
  validates :notes, length: { maximum: 2_000 }, allow_blank: true
  validate :ends_on_not_before_starts_on
  validate :creator_can_edit_workspace, on: :create
  validate :no_open_rollout_when_closing
  validate :active_release_boundary

  before_validation :assign_default_coach_workspace, on: :create
  after_create :ensure_experience_configuration

  private

  def active_release_boundary
    return unless active_cohort_release
    return if active_cohort_release.cohort_id == id && active_cohort_release.coach_workspace_id == coach_workspace_id

    errors.add(:active_cohort_release, "must belong to this cohort and workspace")
  end

  def ensure_experience_configuration
    cohort_experience_configuration || create_cohort_experience_configuration!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG,
      last_edited_by_user: created_by_user,
      coach_workspace: coach_workspace
    )
  end

  def assign_default_coach_workspace
    self.coach_workspace ||= CoachWorkspaces::Provisioner.ensure_for!(created_by_user) if created_by_user&.staff?
  end

  def creator_can_edit_workspace
    return if coach_workspace&.allows?(created_by_user, :edit)

    errors.add(:created_by_user, "cannot create cohorts in this coach workspace")
  end

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

    errors.add(:ends_on, "must be on or after starts on")
  end

  def no_open_rollout_when_closing
    return unless will_save_change_to_status? && status.in?(%w[completed archived])
    return unless cohort_rollouts.where(status: CohortRollout::OPEN_STATUSES).exists?

    errors.add(:status, "cannot be completed or archived while a rollout is planned, active, or paused")
  end
end
