class SavingsPlanDraft < ApplicationRecord
  belongs_to :savings_enrollment
  belongs_to :created_by_user, class_name: "User"
  belongs_to :base_plan_version, class_name: "SavingsPlanVersion", optional: true
  belongs_to :approved_plan_version, class_name: "SavingsPlanVersion", optional: true
  belongs_to :financial_baseline_version, optional: true
  validates :target_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :reason, length: { maximum: 500 }
  validates :status, inclusion: { in: %w[pending approved] }
  validate :participant_boundary

  private

  def participant_boundary
    errors.add(:created_by_user, "must be the participant") unless created_by_user_id == savings_enrollment&.user_id
    errors.add(:target_cents, "must be integer cents or nil") unless target_cents_before_type_cast.nil? || target_cents_before_type_cast.instance_of?(Integer)
    errors.add(:base_plan_version, "must belong to this enrollment") if base_plan_version && base_plan_version.savings_enrollment_id != savings_enrollment_id
  end
end
