class SourceTrackedAccount < SourceReviewImmutableRecord
  belongs_to :account, optional: true
  belongs_to :approved_by_user, class_name: "User"
  validates :label, presence: true, length: { maximum: 120 }
  validates :account_basis, inclusion: { in: %w[asset liability] }
end
