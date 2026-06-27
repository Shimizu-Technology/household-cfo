class FinancialDocumentImportAttempt < ApplicationRecord
  STATUSES = %w[processing succeeded failed].freeze

  belongs_to :financial_document_import, inverse_of: :attempts

  validates :provider, presence: true
  validates :model, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :prompt_version, presence: true
  validates :schema_version, presence: true
  validates :started_at, presence: true
  validate :completed_terminal_attempts_have_completed_at

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  private

  def completed_terminal_attempts_have_completed_at
    return if status == "processing"

    errors.add(:completed_at, "is required when attempt is terminal") if completed_at.blank?
  end
end
