class SavingsEntryVersion < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_entry
  belongs_to :savings_enrollment
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsEntryVersion", optional: true
  validates :version_number, :approval_sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { maximum: 500 }
  validates :approved_at, :effective_on, presence: true
  validate :private_values_valid

  def projection_input
    {
      logical_entry_id: "entry-#{savings_entry_id.to_s.rjust(20, '0')}", version_id: "version-#{id}", approval_state: "approved", current_head: true,
      effective_on: effective_on, signed_cents: signed_cents, currency: currency,
      funding_source: funding_source, evidence_supported_cents: evidence_supported_cents
    }
  end

  private

  def private_values_valid
    errors.add(:signed_cents, "must be integer cents") unless signed_cents_before_type_cast.instance_of?(Integer)
    errors.add(:evidence_supported_cents, "must remain server-set zero") unless evidence_supported_cents_before_type_cast.instance_of?(Integer) && evidence_supported_cents_before_type_cast.zero?
    errors.add(:approved_by_user, "must be the participant") unless approved_by_user_id == savings_enrollment&.user_id
    errors.add(:savings_entry, "must belong to this enrollment") unless savings_entry&.savings_enrollment_id == savings_enrollment_id
    if previous_version
      errors.add(:previous_version, "must precede this entry version") unless previous_version.savings_entry_id == savings_entry_id && version_number == previous_version.version_number + 1
      errors.add(:reason, "is required for a correction") if reason.blank?
    end
    return unless effective_on && savings_enrollment
    errors.add(:effective_on, "must be within the challenge") unless (savings_enrollment.starts_on..savings_enrollment.ends_on).cover?(effective_on)
    errors.add(:effective_on, "cannot approve future actual savings") if effective_on > savings_enrollment.local_today
    HouseholdFinance::SavingsProjection.new(entries: [ projection_input.merge(version_id: "pending-version") ], cutoff_on: effective_on).call
  rescue HouseholdFinance::SavingsProjection::InvalidInput
    errors.add(:base, "Savings values do not match the measurement contract")
  end
end
