class HouseholdProfile < ApplicationRecord
  DEBT_TRACKING_MODES = %w[summary individual].freeze

  belongs_to :household

  validates :household_id, uniqueness: true
  validates :money_stress_level, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
  validates :debt_tracking_mode, inclusion: { in: DEBT_TRACKING_MODES }
  validates :debt_summary_balance_cents, :debt_summary_minimum_payment_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
