class Cohort < ApplicationRecord
  STATUSES = %w[draft enrolling active completed archived].freeze

  belongs_to :created_by_user, class_name: "User"

  has_many :cohort_memberships, dependent: :destroy
  has_many :users, through: :cohort_memberships
  has_one :cohort_persona_assignment, dependent: :destroy, inverse_of: :cohort
  has_one :coach_persona, through: :cohort_persona_assignment
  has_one :coach_persona_version, through: :cohort_persona_assignment
  has_one :cohort_experience_configuration, dependent: :restrict_with_exception, inverse_of: :cohort

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }
  validates :notes, length: { maximum: 2_000 }, allow_blank: true
  validate :ends_on_not_before_starts_on

  after_create :ensure_experience_configuration

  private

  def ensure_experience_configuration
    cohort_experience_configuration || create_cohort_experience_configuration!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG,
      last_edited_by_user: created_by_user
    )
  end

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

    errors.add(:ends_on, "must be on or after starts on")
  end
end
