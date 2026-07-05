class TransactionDraftSplit < ApplicationRecord
  belongs_to :transaction_draft
  belongs_to :budget_category, optional: true

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :category_name, length: { maximum: 120 }, allow_blank: true
  validates :stack_key, inclusion: { in: BudgetCategory::STACK_KEYS }, allow_blank: true
  validates :notes, length: { maximum: 500 }, allow_blank: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true

  scope :ordered, -> { order(:id) }
end
