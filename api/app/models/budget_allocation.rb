class BudgetAllocation < ApplicationRecord
  SOURCES = %w[manual setup imported mia_suggested].freeze

  belongs_to :budget_period
  belongs_to :budget_category

  validates :planned_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source, inclusion: { in: SOURCES }
  validates :budget_category_id, uniqueness: { scope: :budget_period_id }
  validate :associations_belong_to_same_household

  private

  def associations_belong_to_same_household
    return if budget_category.blank? || budget_period.blank?
    return if budget_category.household_id == budget_period.budget_year&.household_id

    errors.add(:budget_category, "must belong to the budget period household")
  end
end
