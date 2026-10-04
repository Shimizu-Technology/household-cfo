class SourceAccountReviewHead < ApplicationRecord
  include SourceReviewScopedRecord
  belongs_to :financial_source_account
  belongs_to :approved_version, class_name: "SourceAccountIdentityVersion", optional: true
  has_many :source_account_identity_versions
  validate :approved_version_scope

  private

  def approved_version_scope
    errors.add(:approved_version, "must belong to this head") if approved_version && approved_version.source_account_review_head_id != id
  end
end
