class SourceEconomicMembership < SourceReviewImmutableRecord
  belongs_to :source_economic_group_version
  belongs_to :source_review_version
  validates :allocation_cents, numericality: { only_integer: true, greater_than: 0 }
end
