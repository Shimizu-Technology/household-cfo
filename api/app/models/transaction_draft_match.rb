class TransactionDraftMatch < ApplicationRecord
  STATUSES = %w[proposed accepted rejected].freeze

  belongs_to :transaction_draft
  belongs_to :household_transaction

  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :match_reason, length: { maximum: 240 }, allow_blank: true

  scope :proposed, -> { where(status: "proposed") }
  scope :accepted, -> { where(status: "accepted") }
  scope :best_first, -> { order(confidence: :desc, id: :asc) }
end
