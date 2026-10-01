class IncomeSource < ApplicationRecord
  CADENCES = %w[weekly biweekly semi_monthly monthly annual one_time].freeze
  SOURCE_TYPES = %w[job business rental passive bonus other].freeze

  belongs_to :household
  has_many :income_schedule_entries, dependent: :destroy

  validates :label, presence: true, length: { maximum: 120 }, uniqueness: {
    scope: [ :household_id, :source_type ], case_sensitive: false, conditions: -> { where(active: true) }
  }, if: :active?
  validates :cadence, inclusion: { in: CADENCES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :temporal_bounds_are_ordered

  def effective_on?(date)
    value = date.to_date
    return false if starts_on && value < starts_on
    return false if ends_on && value >= ends_on

    active? || ends_on.present?
  end

  def intersects_year?(year)
    first = Date.new(year.to_i, 1, 1)
    last = first.end_of_year
    return false if starts_on && starts_on > last
    return false if ends_on && ends_on <= first

    active? || ends_on.present?
  end

  private

  def temporal_bounds_are_ordered
    return if starts_on.blank? || ends_on.blank? || starts_on < ends_on

    errors.add(:ends_on, "must be after the starting month")
  end
end
