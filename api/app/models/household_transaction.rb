class HouseholdTransaction < ApplicationRecord
  STATUSES = %w[confirmed reconciled ignored].freeze
  SOURCE_TYPES = %w[manual_chat manual_ui receipt screenshot statement import plaid].freeze

  belongs_to :household
  belongs_to :budget_period
  belongs_to :source_import, class_name: "FinancialDocumentImport", optional: true
  has_many :transaction_splits, dependent: :destroy
  has_many :budget_categories, through: :transaction_splits
  has_many :transaction_drafts, foreign_key: :confirmed_transaction_id, dependent: :nullify, inverse_of: :confirmed_transaction
  has_many :matched_transaction_drafts, class_name: "TransactionDraft", foreign_key: :matched_transaction_id, dependent: :nullify, inverse_of: :matched_transaction
  has_many :transaction_draft_matches, dependent: :destroy

  validates :occurred_on, presence: true
  validates :merchant, presence: true, length: { maximum: 120 }
  validates :total_amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }

  def validate_split_total!
    return true if transaction_splits.sum(:amount_cents) == total_amount_cents

    errors.add(:base, "Transaction splits must equal transaction total")
    raise ActiveRecord::RecordInvalid, self
  end
end
