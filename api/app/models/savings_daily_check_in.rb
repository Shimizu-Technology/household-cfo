class SavingsDailyCheckIn < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :current_version, class_name: "SavingsDailyCheckInVersion", optional: true
  validates :local_on, presence: true
  validates :local_on, uniqueness: { scope: :savings_enrollment_id }
  validate :current_version_scope

  private

  def current_version_scope
    if current_version && (current_version.savings_daily_check_in_id != id || current_version.savings_enrollment_id != savings_enrollment_id)
      errors.add(:current_version, "must belong to this personal record")
    end
  end
end
