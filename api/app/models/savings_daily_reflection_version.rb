class SavingsDailyReflectionVersion < ApplicationRecord
  include SavingsDailyRecord
  include SavingsImmutable
  belongs_to :savings_daily_reflection
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsDailyReflectionVersion", optional: true
  validates :approved_at, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { maximum: 500 }
  belongs_to :erased_by_user, class_name: "User", optional: true
  validates :feeling_then, :feeling_now, length: { maximum: 500 }
end
