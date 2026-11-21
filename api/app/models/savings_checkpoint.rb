class SavingsCheckpoint < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :current_version, class_name: "SavingsCheckpointVersion", optional: true
  validate :milestone_day_scheduled
  validates :milestone_day, uniqueness: { scope: :savings_enrollment_id }
  validate :current_version_scope

  private

  # Only the check-in days her enrollment started with.
  def milestone_day_scheduled
    errors.add(:milestone_day, "is not one of this challenge's check-in days") unless savings_enrollment && Array(savings_enrollment.checkpoint_days).include?(milestone_day)
  end

  def current_version_scope
    if current_version && (current_version.savings_checkpoint_id != id || current_version.savings_enrollment_id != savings_enrollment_id)
      errors.add(:current_version, "must belong to this personal record")
    end
  end
end
