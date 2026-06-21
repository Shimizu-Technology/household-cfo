class HouseholdProfile < ApplicationRecord
  belongs_to :household

  validates :household_id, uniqueness: true
  validates :money_stress_level, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 10 }, allow_nil: true
end
