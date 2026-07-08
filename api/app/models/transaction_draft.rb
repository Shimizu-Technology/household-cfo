class TransactionDraft < ApplicationRecord
  STATUSES = %w[pending confirmed corrected ignored matched].freeze
  SOURCE_TYPES = HouseholdTransaction::SOURCE_TYPES

  belongs_to :household
  belongs_to :budget_category, optional: true
  belongs_to :financial_document_import, optional: true
  belongs_to :confirmed_transaction, class_name: "HouseholdTransaction", optional: true
  belongs_to :matched_transaction, class_name: "HouseholdTransaction", optional: true

  has_many :transaction_draft_splits, dependent: :destroy
  has_many :transaction_draft_matches, dependent: :destroy

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

  def terminal?
    status.in?(%w[confirmed corrected ignored matched])
  end
end
