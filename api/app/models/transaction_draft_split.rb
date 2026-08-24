class TransactionDraftSplit < ApplicationRecord
  belongs_to :transaction_draft
  belongs_to :budget_category, optional: true

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :category_name, length: { maximum: 120 }, allow_blank: true
  validates :stack_key, inclusion: { in: BudgetCategory::STACK_KEYS }, allow_blank: true
  validates :notes, length: { maximum: 500 }, allow_blank: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :category_belongs_to_draft_household

  scope :ordered, -> { order(:id) }

  private

  def category_belongs_to_draft_household
    return if transaction_draft.blank? || budget_category.blank?
    return if transaction_draft.household_id == budget_category.household_id

    errors.add(:budget_category, "must belong to the transaction draft household")
  end
end
