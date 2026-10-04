class SourceEconomicGroupVersion < SourceReviewImmutableRecord
  belongs_to :source_economic_group
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :supersedes, class_name: "SourceEconomicGroupVersion", optional: true
  has_many :source_economic_memberships
  validates :kind, inclusion: { in: %w[transfer purchase_funding refund] }
  validates :reason, :digest, presence: true
end
