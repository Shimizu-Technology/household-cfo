class TransactionSplit < ApplicationRecord
  belongs_to :household_transaction
  belongs_to :budget_category

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
end
