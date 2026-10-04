class SourceAccountIdentityVersion < SourceReviewImmutableRecord
  belongs_to :source_account_review_head
  belongs_to :source_tracked_account
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :supersedes, class_name: "SourceAccountIdentityVersion", optional: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, :digest, presence: true
end
