class SavingsDailyCheckInVersion < ApplicationRecord
  include SavingsDailyRecord
  include SavingsImmutable
  belongs_to :savings_daily_check_in
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsDailyCheckInVersion", optional: true
  validates :approved_at, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { maximum: 500 }
  validates :spending_state, inclusion: { in: %w[spending no_spend unknown] }
end
