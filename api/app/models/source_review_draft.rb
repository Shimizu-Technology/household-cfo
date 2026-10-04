class SourceReviewDraft < ApplicationRecord
  include SourceReviewScopedRecord
  belongs_to :source_review_head
  belongs_to :staged_by_user, class_name: "User"
  belongs_to :base_version, class_name: "SourceReviewVersion", optional: true
  validates :status, inclusion: { in: %w[pending approved cancelled] }
  validates :reason, :digest, presence: true
  scope :pending, -> { where(status: "pending") }
end
