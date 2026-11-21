class Debt < ApplicationRecord
  include CurrentFinancialPicture
  DEBT_TYPES = %w[credit_card student_loan auto_loan mortgage personal_loan medical other].freeze
  SOURCE_TYPES = %w[manual_ui mia document_import setup].freeze

  belongs_to :household

  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }

  validates :label, presence: true, length: { maximum: 120 }, uniqueness: {
    scope: [ :financial_generation, :household_id, :debt_type ], case_sensitive: false, conditions: -> { active }
  }
  validates :debt_type, inclusion: { in: DEBT_TYPES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :minimum_payment_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :interest_rate_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 999.99 }, allow_nil: true
  # Both optional. A blank past-due amount means "not entered", never "$0 behind".
  validates :due_day, numericality: { only_integer: true, in: 1..31 }, allow_nil: true
  validates :past_due_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :archive_state_is_consistent
  validate :optional_card_identity_is_preserved

  # An entered amount above $0. A blank amount is unknown, so it is never "behind".
  def past_due?
    past_due_cents.to_i.positive?
  end

  private

  def optional_card_identity_is_preserved
    return unless persisted? && will_save_change_to_household_id?

    errors.add(:household_id, "cannot change because optional card review history belongs to this household") if optional_card_history_referenced?
  end

  def optional_card_history_referenced?
    SavingsDebtCard.where(household_debt_id: id).exists? || SavingsDebtDraft.where(household_debt_id: id).exists? || SavingsDebtVersion.where(household_debt_id: id).exists?
  end

  def archive_state_is_consistent
    return if active? ? archived_at.nil? : archived_at.present?

    errors.add(:archived_at, active? ? "must be blank for an active debt" : "is required for an archived debt")
  end
end
