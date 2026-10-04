class SavingsDailyLedger < ApplicationRecord
  include SavingsDailyRecord
  validates :savings_enrollment_id, uniqueness: true
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def advance!
    update!(sequence: sequence + 1)
    sequence
  end
end
