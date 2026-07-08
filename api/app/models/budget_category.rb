class BudgetCategory < ApplicationRecord
  STACK_KEYS = ExpenseItem::STACK_KEYS

  belongs_to :household
  has_many :budget_allocations, dependent: :destroy
  has_many :transaction_splits, dependent: :restrict_with_exception
  has_many :transaction_drafts, dependent: :nullify
  has_many :transaction_draft_splits, dependent: :nullify
  has_many :merchant_category_rules, dependent: :destroy

  validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :household_id, case_sensitive: false }
  validates :stack_key, inclusion: { in: STACK_KEYS }
  validates :sort_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }
  scope :ordered, -> { order(:sort_order, :name) }

  def stack_label
    HouseholdFinance::SnapshotBuilder::STACK_LABELS.fetch(stack_key, stack_key.to_s.humanize.presence || "Custom")
  end
end
