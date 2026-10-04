class SourceReviewVersion < SourceReviewImmutableRecord
  belongs_to :source_review_head
  belongs_to :source_account_identity_version
  belongs_to :budget_category, optional: true
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :supersedes, class_name: "SourceReviewVersion", optional: true
  belongs_to :matched_version, class_name: "SourceReviewVersion", optional: true
  has_one :source_projection_revision
  validates :disposition, inclusion: { in: %w[include match exclude informational] }
  validates :event_type, inclusion: { in: FinancialSourceEvent::TYPES }
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, :digest, presence: true

  def financial_source_event
    source_review_head.financial_source_event
  end

  def source_tracked_account
    source_account_identity_version.source_tracked_account
  end

  def expense?
    disposition == "include" && signed_amount_cents.to_i.negative? && event_type.in?(%w[purchase fee interest])
  end

  def reviewed_facts
    attributes.symbolize_keys.slice(:source_account_identity_version_id, :disposition, :event_type, :signed_amount_cents, :purchase_amount_cents, :merchant, :budget_category_id, :matched_version_id, :external_reference, :overlap_disposition)
      .merge(posted_on: posted_on&.iso8601, authorized_on: authorized_on&.iso8601)
  end
end
