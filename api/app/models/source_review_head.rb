class SourceReviewHead < ApplicationRecord
  include SourceReviewScopedRecord
  belongs_to :financial_source_event
  belongs_to :approved_version, class_name: "SourceReviewVersion", optional: true
  has_many :source_review_versions
  has_many :source_review_drafts
  validate :approved_version_scope

  private

  def approved_version_scope
    errors.add(:approved_version, "must belong to this head") if approved_version && approved_version.source_review_head_id != id
  end
end
