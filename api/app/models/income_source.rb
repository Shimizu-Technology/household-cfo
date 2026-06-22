class IncomeSource < ApplicationRecord
  CADENCES = %w[weekly biweekly semi_monthly monthly annual one_time].freeze
  SOURCE_TYPES = %w[job business rental passive bonus other].freeze

  belongs_to :household

  validates :label, presence: true, uniqueness: { scope: [ :household_id, :source_type ] }
  validates :cadence, inclusion: { in: CADENCES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
