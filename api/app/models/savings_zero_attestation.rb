class SavingsZeroAttestation < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_enrollment
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_attestation, class_name: "SavingsZeroAttestation", optional: true
  validates :cutoff_on, :approved_at, presence: true
  validates :approval_sequence, numericality: { only_integer: true, greater_than: 0 }
  validate :participant_boundary

  private

  def participant_boundary
    errors.add(:approved_by_user, "must be the participant") unless approved_by_user_id == savings_enrollment&.user_id
    if previous_attestation && (previous_attestation.savings_enrollment_id != savings_enrollment_id || previous_attestation.cutoff_on != cutoff_on)
      errors.add(:previous_attestation, "must be for the same enrollment and cutoff")
    end
  end
end
