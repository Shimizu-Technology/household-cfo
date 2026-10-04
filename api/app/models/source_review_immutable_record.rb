class SourceReviewImmutableRecord < ApplicationRecord
  self.abstract_class = true
  include SourceReviewScopedRecord

  def readonly?
    persisted?
  end
end
