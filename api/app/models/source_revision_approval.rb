class SourceRevisionApproval < SourceReviewImmutableRecord
  belongs_to :financial_extraction_revision
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :supersedes, class_name: "SourceRevisionApproval", optional: true
  validates :coverage_status, inclusion: { in: %w[complete qualified] }
  validates :reason, :digest, presence: true
end
