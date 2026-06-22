class Debt < ApplicationRecord
  DEBT_TYPES = %w[credit_card student_loan auto_loan mortgage personal_loan medical other].freeze

  belongs_to :household

  validates :label, presence: true, uniqueness: { scope: [ :household_id, :debt_type ] }
  validates :debt_type, inclusion: { in: DEBT_TYPES }
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :minimum_payment_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
