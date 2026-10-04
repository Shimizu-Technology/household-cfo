class SavingsEvidenceVersion < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_evidence_allocation
  belongs_to :savings_enrollment
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsEvidenceVersion", optional: true
  has_many :savings_evidence_capacities, dependent: :restrict_with_exception
  validates :state, inclusion: { in: %w[attached revoked] }
  validates :digest, :approved_at, presence: true
  validate :exact_values

  private

  def exact_values
    cents = supported_cents_before_type_cast
    errors.add(:supported_cents, "must be exact integer cents") unless cents.instance_of?(Integer) && cents >= 0
    errors.add(:proof_snapshot, "must be a reviewed array") unless proof_snapshot.instance_of?(Array)
    errors.add(:approved_by_user, "must be this enrollment's participant") unless approved_by_user_id == savings_enrollment&.user_id
    errors.add(:savings_enrollment, "must match the allocation") unless savings_enrollment_id == savings_evidence_allocation&.savings_enrollment_id
  end
end
