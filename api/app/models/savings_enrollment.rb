class SavingsEnrollment < ApplicationRecord
  TIME_ZONE = "Pacific/Guam".freeze
  STATUSES = %w[active withdrawn completed].freeze

  has_many :savings_chat_cards, dependent: :destroy
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

  # One enrollment per person per group. The one exception is a staff preview that
  # was withdrawn: it stays as history and does not stop a fresh enrollment.
  validates :user_id, uniqueness: { scope: :cohort_id, conditions: -> { in_use } }, unless: :ended_preview?
  validates :status, inclusion: { in: STATUSES }
  validates :time_zone, inclusion: { in: [ TIME_ZONE ] }
  validates :accepted_at, :accepted_local_on, :starts_on, :ends_on, :policy_version,
    :accepted_cohort_membership_id, :membership_started_at, presence: true
  validate :calendar_valid
  validate :accepted_release_scope

  # Enrollments of people who are in the program: accepted through a membership
  # whose role is `participant`. Defined positively so that anything unexpected (a
  # preview, a membership that was removed or changed) is not counted. Every
  # roster, count, cap, report, export and reminder over a cohort goes through
  # `counted`. (A person's own enrollment is looked up by user, not by cohort.)
  scope :counted, -> { where(staff_preview: false, accepted_cohort_membership_id: CohortMembership.where(role: "participant").select(:id)) }
  # A staff member's challenge preview, accepted through a preview seat.
  scope :previews, -> { where(staff_preview: true) }
  # Everything except a staff preview that ended. Lookups of "this person's
  # enrollment in this group" use it, so an old preview never hides the real one.
  scope :in_use, -> { where("NOT (savings_enrollments.staff_preview AND savings_enrollments.status = 'withdrawn')") }

  def preview?
    staff_preview
  end

  def ended_preview?
    staff_preview && status == "withdrawn"
  end

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
