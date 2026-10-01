class IncomeScheduleEntry < ApplicationRecord
  ENTRY_TYPES = %w[recurring_change one_time].freeze

  belongs_to :income_source

  validates :entry_type, inclusion: { in: ENTRY_TYPES }
  validates :cadence, inclusion: { in: IncomeSource::CADENCES }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :effective_on, presence: true
  validates :effective_on, uniqueness: { scope: :income_source_id }, if: :recurring_change?
  validates :label, length: { maximum: 80 }, allow_blank: true
  validate :one_time_cadence
  validate :one_time_amount
  validate :recurring_cadence
  validate :continuing_transition_income
  validate :retained_income_belongs_to_job
  validate :effective_month_is_within_source_timeline

  private

  def recurring_change?
    entry_type == "recurring_change"
  end

  def one_time_cadence
    return unless entry_type == "one_time" && cadence != "one_time"

    errors.add(:cadence, "must be one_time for a one-time entry")
  end

  def one_time_amount
    return unless entry_type == "one_time" && amount_cents.to_i <= 0

    errors.add(:amount_cents, "must be greater than zero for one-time income")
  end

  def recurring_cadence
    return unless entry_type == "recurring_change" && cadence == "one_time"

    errors.add(:cadence, "cannot be one_time for a recurring change")
  end

  def continuing_transition_income
    return unless retained_after_transition?
    return if entry_type == "recurring_change" && amount_cents.to_i.positive?

    errors.add(:retained_after_transition, "requires a continuing recurring income amount")
  end

  def retained_income_belongs_to_job
    return unless retained_after_transition?
    return if income_source&.source_type == "job"

    errors.add(:retained_after_transition, "is available only for job income")
  end

  def effective_month_is_within_source_timeline
    return if effective_on.blank? || income_source.blank?
    return if income_source.effective_on?(effective_on)

    errors.add(:effective_on, "must be within the income source timeline")
  end
end
