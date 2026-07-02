class BudgetYear < ApplicationRecord
  STATUSES = %w[draft active archived].freeze

  belongs_to :household
  has_many :budget_periods, dependent: :destroy

  validates :year, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2100 }
  validates :year, uniqueness: { scope: :household_id }
  validates :status, inclusion: { in: STATUSES }
end
