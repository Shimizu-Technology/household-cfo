class TransactionDraftMatch < ApplicationRecord
  STATUSES = %w[proposed accepted rejected].freeze

  belongs_to :transaction_draft
  belongs_to :household_transaction

  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :match_reason, length: { maximum: 240 }, allow_blank: true
  validate :transaction_belongs_to_draft_household

  scope :proposed, -> { where(status: "proposed") }
  scope :accepted, -> { where(status: "accepted") }
  scope :best_first, -> { order(confidence: :desc, id: :asc) }

  private

  def transaction_belongs_to_draft_household
    return if transaction_draft.blank? || household_transaction.blank?
    return if transaction_draft.household_id == household_transaction.household_id

    errors.add(:household_transaction, "must belong to the transaction draft household")
  end
end
