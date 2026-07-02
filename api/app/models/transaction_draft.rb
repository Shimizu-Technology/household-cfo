class TransactionDraft < ApplicationRecord
  STATUSES = %w[pending confirmed corrected ignored].freeze
  SOURCE_TYPES = HouseholdTransaction::SOURCE_TYPES

  belongs_to :household
  belongs_to :budget_category, optional: true
  belongs_to :financial_document_import, optional: true
  belongs_to :confirmed_transaction, class_name: "HouseholdTransaction", optional: true

  validates :occurred_on, presence: true
  validates :merchant, presence: true, length: { maximum: 120 }
  validates :total_amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def pending?
    status == "pending"
  end
end
