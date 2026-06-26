class Cohort < ApplicationRecord
  STATUSES = %w[draft enrolling active completed archived].freeze

  belongs_to :created_by_user, class_name: "User"

  has_many :cohort_memberships, dependent: :destroy
  has_many :users, through: :cohort_memberships

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }
  validates :notes, length: { maximum: 2_000 }, allow_blank: true
  validate :ends_on_not_before_starts_on

  private

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

    errors.add(:ends_on, "must be on or after starts on")
  end
end
