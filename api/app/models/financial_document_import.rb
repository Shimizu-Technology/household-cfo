class FinancialDocumentImport < ApplicationRecord
  DOCUMENT_KINDS = %w[spreadsheet statement pay_stub receipt other].freeze
  STATUSES = %w[uploaded processing needs_review applied partially_applied failed source_deleted].freeze
  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  PDF_CONTENT_TYPES = %w[application/pdf].freeze
  SPREADSHEET_CONTENT_TYPES = %w[text/csv application/csv application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet].freeze

  belongs_to :household
  belongs_to :uploaded_by_user, class_name: "User"
  belongs_to :applied_by_user, class_name: "User", optional: true
  belongs_to :source_deleted_by_user, class_name: "User", optional: true

  has_many :items, class_name: "FinancialDocumentImportItem", dependent: :destroy, inverse_of: :financial_document_import
  has_many :attempts, class_name: "FinancialDocumentImportAttempt", dependent: :destroy, inverse_of: :financial_document_import

  validates :document_kind, inclusion: { in: DOCUMENT_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :filename, presence: true, length: { maximum: 255 }
  validates :content_type, presence: true, length: { maximum: 255 }
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :checksum_sha256, length: { is: 64 }, allow_blank: true
  validates :s3_key, length: { maximum: 1024 }, allow_blank: true
  validate :source_present_for_active_import

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :pending_review, -> { where(status: "needs_review") }
  scope :applied_recent_first, -> { where(status: %w[applied partially_applied]).order(Arel.sql("COALESCE(applied_at, updated_at) DESC"), id: :desc) }

  def image?
    content_type.in?(IMAGE_CONTENT_TYPES) || File.extname(filename.to_s).downcase.in?(%w[.jpg .jpeg .png .webp])
  end

  def pdf?
    content_type.in?(PDF_CONTENT_TYPES) || File.extname(filename.to_s).downcase == ".pdf"
  end

  def spreadsheet?
    content_type.in?(SPREADSHEET_CONTENT_TYPES) || File.extname(filename.to_s).downcase.in?(%w[.csv .xlsx])
  end

  def source_available?
    s3_key.present? && source_deleted_at.blank?
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

  def source_present_for_active_import
    return if new_record?
    return if s3_key.present?
    return if terminal_without_source? || applied? || partially_applied?

    errors.add(:s3_key, "is required while the document source is active")
  end
end
