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
end
