class SavingsDailyReflection < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :current_version, class_name: "SavingsDailyReflectionVersion", optional: true
  belongs_to :savings_daily_purchase
  validate :current_version_scope

  private

  def current_version_scope
    if current_version && (current_version.savings_daily_reflection_id != id || current_version.savings_enrollment_id != savings_enrollment_id)
      errors.add(:current_version, "must belong to this personal record")
    end
  end
end
