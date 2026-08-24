class TransactionSplit < ApplicationRecord
  belongs_to :household_transaction
  belongs_to :budget_category

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validate :category_belongs_to_transaction_household

  private

  def category_belongs_to_transaction_household
    return if household_transaction.blank? || budget_category.blank?
    return if household_transaction.household_id == budget_category.household_id

    errors.add(:budget_category, "must belong to the transaction household")
  end
end
