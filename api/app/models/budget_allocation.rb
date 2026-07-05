class BudgetAllocation < ApplicationRecord
  SOURCES = %w[manual setup imported mia_suggested].freeze

  belongs_to :budget_period
  belongs_to :budget_category

  validates :planned_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source, inclusion: { in: SOURCES }
  validates :budget_category_id, uniqueness: { scope: :budget_period_id }
end
