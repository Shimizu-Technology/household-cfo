class SavingsDailyPurchase < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :current_version, class_name: "SavingsDailyPurchaseVersion", optional: true
  validate :current_version_scope

  private

  def current_version_scope
    if current_version && (current_version.savings_daily_purchase_id != id || current_version.savings_enrollment_id != savings_enrollment_id)
      errors.add(:current_version, "must belong to this personal record")
    end
  end
end
