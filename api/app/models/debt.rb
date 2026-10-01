class Debt < ApplicationRecord
  DEBT_TYPES = %w[credit_card student_loan auto_loan mortgage personal_loan medical other].freeze
  SOURCE_TYPES = %w[manual_ui mia document_import setup].freeze

  belongs_to :household

  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }

  validates :label, presence: true, length: { maximum: 120 }, uniqueness: {
    scope: [ :household_id, :debt_type ], case_sensitive: false, conditions: -> { active }
  }
  validates :debt_type, inclusion: { in: DEBT_TYPES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :minimum_payment_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :interest_rate_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 999.99 }, allow_nil: true
  validate :archive_state_is_consistent

  private

  def archive_state_is_consistent
    return if active? ? archived_at.nil? : archived_at.present?

    errors.add(:archived_at, active? ? "must be blank for an active debt" : "is required for an archived debt")
  end
end
