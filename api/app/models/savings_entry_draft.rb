class SavingsEntryDraft < ApplicationRecord
  belongs_to :savings_entry
  belongs_to :created_by_user, class_name: "User"
  belongs_to :base_version, class_name: "SavingsEntryVersion", optional: true
  belongs_to :approved_version, class_name: "SavingsEntryVersion", optional: true
  validates :status, inclusion: { in: %w[pending approved] }
  validates :funding_source, inclusion: { in: HouseholdFinance::SavingsProjection::FUNDING_SOURCES }
  validates :effective_on, presence: true
  validates :reason, length: { maximum: 500 }
  validates :base_entry_lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :participant_boundary

  def savings_enrollment
    savings_entry.savings_enrollment
  end

  private

  def participant_boundary
    errors.add(:created_by_user, "must be the participant") unless created_by_user_id == savings_enrollment.user_id
    errors.add(:signed_cents, "must be integer cents") unless signed_cents_before_type_cast.instance_of?(Integer)
    errors.add(:base_version, "must belong to this entry") if base_version && base_version.savings_entry_id != savings_entry_id
    errors.add(:reason, "is required for a correction") if base_version && reason.blank?
    if effective_on && !(savings_enrollment.starts_on..savings_enrollment.ends_on).cover?(effective_on)
      errors.add(:effective_on, "must be within the challenge")
    end
    if signed_cents && ((funding_source == "withdrawal" && signed_cents.positive?) || (funding_source != "withdrawal" && signed_cents.negative?))
      errors.add(:signed_cents, "must match the funding classification")
    end
  end
end
