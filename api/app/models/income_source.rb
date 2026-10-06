class IncomeSource < ApplicationRecord
  include CurrentFinancialPicture
  CADENCES = %w[weekly biweekly semi_monthly monthly annual one_time].freeze
  SOURCE_TYPES = %w[job business rental passive bonus other].freeze

  belongs_to :household
  has_many :income_schedule_entries, dependent: :destroy

  validates :label, presence: true, length: { maximum: 120 }, uniqueness: {
    scope: [ :financial_generation, :household_id, :source_type ], case_sensitive: false, conditions: -> { where(active: true) }
  }, if: :active?
  validates :cadence, inclusion: { in: CADENCES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :temporal_bounds_are_ordered
  validate :timeline_does_not_overlap
  validate :start_does_not_strand_schedule_entries

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

  def timeline_status(on: Date.current)
    date = on.to_date
    return "current" if effective_on?(date)
    return "future" if active? && starts_on.present? && starts_on > date
    return "ended" if ends_on.present? && ends_on <= date

    "archived"
  end

  def schedule_entry_active?(entry)
    effective_on?(entry.effective_on)
  end

  private

  def temporal_bounds_are_ordered
    return if starts_on.blank? || ends_on.blank? || starts_on <= ends_on

    errors.add(:ends_on, "cannot be before the starting month")
  end

  def timeline_does_not_overlap
    return if household_id.blank? || source_type.blank? || label.blank?
    return unless active? || ends_on.present?
    return if !active? && starts_on.present? && ends_on == starts_on

    scope = self.class
      .where(financial_generation: financial_generation, household_id: household_id, source_type: source_type)
      .where("LOWER(label) = ?", label.downcase)
      .where("active = TRUE OR ends_on IS NOT NULL")
      .where.not("active = FALSE AND starts_on IS NOT NULL AND ends_on = starts_on")
    scope = scope.where.not(id: id) if persisted?
    scope = scope.where("starts_on IS NULL OR starts_on < ?", ends_on) if ends_on.present?
    scope = scope.where("ends_on IS NULL OR ends_on > ?", starts_on) if starts_on.present?
    return unless scope.exists?

    errors.add(:starts_on, "overlaps another income source with this name and type")
  end

  def start_does_not_strand_schedule_entries
    return if starts_on.blank? || !persisted?
    return unless income_schedule_entries.where("effective_on < ?", starts_on).exists?

    errors.add(:starts_on, "cannot begin after an existing income change")
  end
end
