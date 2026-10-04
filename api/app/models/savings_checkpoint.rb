class SavingsCheckpoint < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :current_version, class_name: "SavingsCheckpointVersion", optional: true
  validates :milestone_day, inclusion: { in: [ 30, 60, 90 ] }
  validates :milestone_day, uniqueness: { scope: :savings_enrollment_id }
  validate :current_version_scope

  private

  def current_version_scope
    if current_version && (current_version.savings_checkpoint_id != id || current_version.savings_enrollment_id != savings_enrollment_id)
      errors.add(:current_version, "must belong to this personal record")
    end
  end
end
