class ExpenseItem < ApplicationRecord
  CADENCES = IncomeSource::CADENCES
  STACK_KEYS = %w[non_discretionary discretionary sinking_expected sinking_unexpected].freeze

  belongs_to :household

  validates :label, presence: true, uniqueness: { scope: [ :household_id, :stack_key ] }
  validates :cadence, inclusion: { in: CADENCES }
  validates :stack_key, inclusion: { in: STACK_KEYS }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
