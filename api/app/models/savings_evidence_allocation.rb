class SavingsEvidenceAllocation < ApplicationRecord
  belongs_to :household
  belongs_to :savings_enrollment
  belongs_to :savings_entry_version
  belongs_to :current_version, class_name: "SavingsEvidenceVersion", optional: true
  has_many :savings_evidence_versions, dependent: :restrict_with_exception
  validates :savings_entry_version_id, uniqueness: true
end
