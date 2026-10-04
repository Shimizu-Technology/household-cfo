class SavingsPlanVersion < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_enrollment
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsPlanVersion", optional: true
  belongs_to :financial_baseline_version, optional: true
  validates :version_number, :approval_sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :target_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :reason, length: { maximum: 500 }
  validates :approved_at, presence: true
  validate :private_values_valid

  private

  def private_values_valid
    errors.add(:target_cents, "must be integer cents or nil") unless target_cents_before_type_cast.nil? || target_cents_before_type_cast.instance_of?(Integer)
    errors.add(:approved_by_user, "must be the participant") unless approved_by_user_id == savings_enrollment&.user_id
    if previous_version
      errors.add(:previous_version, "must be this enrollment's preceding version") unless previous_version.savings_enrollment_id == savings_enrollment_id && version_number == previous_version.version_number + 1
      errors.add(:reason, "is required for a plan revision") if reason.blank?
    end
  end
end
