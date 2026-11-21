class Bill < ApplicationRecord
  include CurrentFinancialPicture
  include BoundedCents
  bounded_cents :amount_cents

  belongs_to :household
  belongs_to :budget_category, optional: true
  validates :name, presence: true, length: { maximum: 80 }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :due_on, presence: true
  validates :repeat_months, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 120 }, allow_nil: true
  validate :category_in_picture

  def due_in(month)
    return unless due_on
    distance = (month.year - due_on.year) * 12 + month.month - due_on.month
    return if distance.negative? || (repeat_months ? distance % repeat_months != 0 : distance != 0)
    Date.new(month.year, month.month, [ due_on.day, month.end_of_month.day ].min)
  end

  private

  def category_in_picture
    return unless budget_category
    unless budget_category.household_id == household_id && budget_category.financial_generation == financial_generation && budget_category.active?
      errors.add(:budget_category, "must be an active category in your current plan")
    end
  end
end
