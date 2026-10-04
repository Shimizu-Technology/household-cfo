class SourceProjectionRevision < SourceReviewImmutableRecord
  belongs_to :source_review_version
  belongs_to :previous_transaction, class_name: "HouseholdTransaction", optional: true
  belongs_to :replacement_transaction, class_name: "HouseholdTransaction", optional: true
  belongs_to :approved_by_user, class_name: "User"
  validates :action, inclusion: { in: %w[create replace void] }
end
