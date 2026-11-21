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
  validate :paid_only_once

  # A one-time bill she marked paid is done; it never counts again.
  scope :unpaid, -> { where(paid_on: nil) }

  def one_time? = repeat_months.nil?

  # A one-time bill whose date has passed and that she has not marked paid: still counted as due until she answers.
  def awaiting_answer?(today)
    one_time? && paid_on.nil? && due_on < today
  end

  def due_in(month)
    return unless due_on
    distance = (month.year - due_on.year) * 12 + month.month - due_on.month
    return if distance.negative? || (repeat_months ? distance % repeat_months != 0 : distance != 0)
    Date.new(month.year, month.month, [ due_on.day, month.end_of_month.day ].min)
  end

  # Every date this bill is due in from..to, oldest first.
  def due_dates(from, to)
    month = from.beginning_of_month
    dates = []
    while month <= to
      date = due_in(month)
      dates << date if date && date.between?(from, to)
      month = month.next_month
    end
    dates
  end

  private

  def category_in_picture
    return unless budget_category
    unless budget_category.household_id == household_id && budget_category.financial_generation == financial_generation && budget_category.active?
      errors.add(:budget_category, "must be an active category in your current plan")
    end
  end

  def paid_only_once
    errors.add(:paid_on, "can only be set on a one-time bill") if paid_on && !one_time?
  end
end
