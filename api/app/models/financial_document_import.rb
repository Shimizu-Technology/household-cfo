class FinancialDocumentImport < ApplicationRecord
  include CurrentFinancialPicture
  DOCUMENT_KINDS = %w[spreadsheet statement pay_stub receipt other].freeze
  # nothing_applied: review finished (every value ignored, or nothing to
  # review) and nothing from the document was saved. Not an approved source.
  STATUSES = %w[uploaded processing needs_review applied partially_applied nothing_applied failed source_deleted].freeze
  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
  PDF_CONTENT_TYPES = %w[application/pdf].freeze
  SPREADSHEET_CONTENT_TYPES = %w[text/csv application/csv application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet].freeze
  WORD_CONTENT_TYPES = %w[application/vnd.openxmlformats-officedocument.wordprocessingml.document].freeze

  belongs_to :household
  belongs_to :uploaded_by_user, class_name: "User"
  belongs_to :applied_by_user, class_name: "User", optional: true
  belongs_to :source_deleted_by_user, class_name: "User", optional: true

  has_one :extraction_dispatch, class_name: "FinancialDocumentExtractionDispatch", dependent: :nullify

  has_many :items, class_name: "FinancialDocumentImportItem", dependent: :destroy, inverse_of: :financial_document_import
  has_many :attempts, class_name: "FinancialDocumentImportAttempt", dependent: :destroy, inverse_of: :financial_document_import
  has_many :transaction_drafts, dependent: :destroy
  has_many :financial_extraction_revisions, dependent: :nullify

  before_destroy :erase_source_evidence, prepend: true

  validates :document_kind, inclusion: { in: DOCUMENT_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :filename, presence: true, length: { maximum: 255 }
  validates :content_type, presence: true, length: { maximum: 255 }
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :checksum_sha256, length: { is: 64 }, allow_blank: true
  validates :s3_key, length: { maximum: 1024 }, allow_blank: true
  validate :source_present_for_active_import

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :pending_review, -> {
    where.not(status: %w[failed source_deleted]).where("status IN (?) OR metadata @> ?", %w[needs_review partially_applied], { source_accounting_review_pending: true }.to_json)
  }
  scope :applied_recent_first, -> { where(status: %w[applied partially_applied]).order(Arel.sql("COALESCE(applied_at, updated_at) DESC"), id: :desc) }
  # The one definition of "something from this import was approved",
  # shared by status reconciliation, reprocess/delete guards and Mia's
  # approved-source context. Any of: an applied setup value; a confirmed,
  # corrected or matched draft; a live actual created from the import
  # (including source-review projections); an approved source revision,
  # source row or account identity; savings evidence built on its rows.
  APPROVED_VALUES_SQL = <<~SQL.squish.freeze
    EXISTS (SELECT 1 FROM financial_document_import_items approved_items
      WHERE approved_items.financial_document_import_id = financial_document_imports.id AND approved_items.applied_at IS NOT NULL)
    OR EXISTS (SELECT 1 FROM transaction_drafts approved_drafts
      WHERE approved_drafts.financial_document_import_id = financial_document_imports.id AND approved_drafts.status IN ('confirmed', 'corrected', 'matched'))
    OR EXISTS (SELECT 1 FROM household_transactions approved_actuals
      WHERE approved_actuals.source_import_id = financial_document_imports.id AND approved_actuals.status IN ('confirmed', 'reconciled'))
    OR EXISTS (SELECT 1 FROM financial_extraction_revisions approved_revisions
      WHERE approved_revisions.financial_document_import_id = financial_document_imports.id AND (
        EXISTS (SELECT 1 FROM source_revision_approvals approvals WHERE approvals.financial_extraction_revision_id = approved_revisions.id)
        OR EXISTS (SELECT 1 FROM financial_source_events approved_events
          WHERE approved_events.financial_extraction_revision_id = approved_revisions.id AND (
            EXISTS (SELECT 1 FROM source_review_heads row_heads WHERE row_heads.financial_source_event_id = approved_events.id AND row_heads.approved_version_id IS NOT NULL)
            OR EXISTS (SELECT 1 FROM household_transactions event_actuals WHERE event_actuals.financial_source_event_id = approved_events.id AND event_actuals.status IN ('confirmed', 'reconciled'))
            OR EXISTS (SELECT 1 FROM savings_evidence_capacities capacities WHERE capacities.financial_source_event_id = approved_events.id)))
        OR EXISTS (SELECT 1 FROM financial_source_accounts approved_accounts
          INNER JOIN source_account_review_heads account_heads ON account_heads.financial_source_account_id = approved_accounts.id
          WHERE approved_accounts.financial_extraction_revision_id = approved_revisions.id AND account_heads.approved_version_id IS NOT NULL)))
  SQL
  scope :with_approved_values, -> { where(APPROVED_VALUES_SQL) }

  def image?
    content_type.in?(IMAGE_CONTENT_TYPES) || File.extname(filename.to_s).downcase.in?(%w[.jpg .jpeg .png .webp .heic .heif])
  end

  def pdf?
    content_type.in?(PDF_CONTENT_TYPES) || File.extname(filename.to_s).downcase == ".pdf"
  end

  def spreadsheet?
    content_type.in?(SPREADSHEET_CONTENT_TYPES) || File.extname(filename.to_s).downcase.in?(%w[.csv .xls .xlsx])
  end

  def word_document?
    content_type.in?(WORD_CONTENT_TYPES) || File.extname(filename.to_s).downcase == ".docx"
  end

  def source_available?
    return false unless s3_key.present? && source_deleted_at.blank?
    uses = FinancialSourceUse.where(financial_document_import_id: id)
    !uses.exists? || uses.where(revoked_at: nil).where("expires_at > ?", Time.current).exists?
  end

  def terminal_without_source?
    status.in?(%w[failed source_deleted])
  end

  def applied?
    status == "applied"
  end

  def partially_applied?
    status == "partially_applied"
  end

  def nothing_applied?
    status == "nothing_applied"
  end

  def approved_values?
    persisted? && self.class.unscoped.where(id: id).with_approved_values.exists?
  end

  def failed?
    status == "failed"
  end

  def processing?
    status == "processing"
  end

  def needs_review?
    status == "needs_review"
  end

  private

  def erase_source_evidence
    FinancialDocuments::SourceEvidenceEraser.call(self)
  end

  def source_present_for_active_import
    return if new_record?
    return if s3_key.present?
    return if terminal_without_source? || applied? || partially_applied? || nothing_applied?

    errors.add(:s3_key, "is required while the document source is active")
  end
end
