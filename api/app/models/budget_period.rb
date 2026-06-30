class BudgetPeriod < ApplicationRecord
  STATUSES = %w[open reviewing closed].freeze

  belongs_to :budget_year
  has_many :budget_allocations, dependent: :destroy
  has_many :budget_categories, through: :budget_allocations
  has_many :household_transactions, dependent: :restrict_with_exception

  validates :starts_on, :ends_on, presence: true
  validates :starts_on, uniqueness: { scope: :budget_year_id }
  validates :status, inclusion: { in: STATUSES }
  validate :ends_on_after_starts_on

  private

  def ends_on_after_starts_on
    return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

    errors.add(:ends_on, "must be on or after the start date")
  end
end
