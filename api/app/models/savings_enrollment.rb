class SavingsEnrollment < ApplicationRecord
  TIME_ZONE = "Pacific/Guam".freeze
  STATUSES = %w[active withdrawn completed].freeze

  belongs_to :household
  belongs_to :user
  belongs_to :cohort
  belongs_to :accepted_cohort_release, class_name: "CohortRelease"
  belongs_to :current_accepted_plan_version, class_name: "SavingsPlanVersion", optional: true
  has_many :savings_plan_versions, dependent: :restrict_with_exception
  has_many :savings_plan_drafts, dependent: :restrict_with_exception
  has_many :savings_entries, dependent: :restrict_with_exception
  has_many :savings_entry_versions, dependent: :restrict_with_exception
  has_many :savings_zero_attestations, dependent: :restrict_with_exception

  validates :user_id, uniqueness: { scope: :cohort_id }
  validates :status, inclusion: { in: STATUSES }
  validates :time_zone, inclusion: { in: [ TIME_ZONE ] }
  validates :accepted_at, :accepted_local_on, :starts_on, :ends_on, :policy_version,
    :accepted_cohort_membership_id, :membership_started_at, presence: true
  validate :calendar_valid
  validate :accepted_release_scope

  def local_today
    Time.current.in_time_zone(time_zone).to_date
  end

  def advance_approval_sequence!
    update!(approval_sequence: approval_sequence + 1)
    approval_sequence
  end

  private

  def accepted_release_scope
    return if accepted_cohort_release && accepted_cohort_release.cohort_id == cohort_id

    errors.add(:accepted_cohort_release, "must belong to the accepted cohort")
  end

  def calendar_valid
    return unless starts_on && ends_on && accepted_local_on
    errors.add(:ends_on, "must be the inclusive ninetieth day") unless ends_on == starts_on + 89
    errors.add(:starts_on, "cannot precede acceptance") if starts_on < accepted_local_on
  end
end
