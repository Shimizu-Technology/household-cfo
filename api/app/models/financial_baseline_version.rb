class FinancialBaselineVersion < SourceReviewImmutableRecord
  belongs_to :financial_baseline_head
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :supersedes, class_name: "FinancialBaselineVersion", optional: true
  validate :actual_participant_scope
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :coverage_status, inclusion: { in: %w[complete partial manual] }
  validates :digest, :snapshot, :reason, :calculation_version, presence: true

  private

  def actual_participant_scope
    errors.add(:approved_by_user, "must be this baseline's participant") if financial_baseline_head && financial_baseline_head.participant_user_id != approved_by_user_id
  end
end
