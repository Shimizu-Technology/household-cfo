class SavingsEvidenceCapacity < ApplicationRecord
  include SavingsImmutable
  belongs_to :savings_evidence_version
  belongs_to :financial_source_event
  belongs_to :source_review_version
end
