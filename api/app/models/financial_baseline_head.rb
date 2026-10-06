class FinancialBaselineHead < ApplicationRecord
  include CurrentFinancialPicture
  include SourceReviewScopedRecord
  belongs_to :participant_user, class_name: "User"
  belongs_to :approved_version, class_name: "FinancialBaselineVersion", optional: true
  has_many :financial_baseline_versions
  validates :participant_user_id, uniqueness: { scope: [ :household_id, :financial_generation ] }
  validate :approved_head_scope

  private

  def approved_head_scope
    errors.add(:approved_version, "must belong to this head") if approved_version && approved_version.financial_baseline_head_id != id
  end
end
