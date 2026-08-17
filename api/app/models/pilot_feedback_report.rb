class PilotFeedbackReport < ApplicationRecord
  WORKFLOWS = %w[
    sign_in
    home
    setup
    ask_mia
    voice
    budget
    transaction_review
    receipt_upload
    statement_upload
    document_upload
    private_document
    admin
    other
  ].freeze
  STATUSES = %w[submitted reviewed resolved].freeze
  MAX_DETAIL_LENGTH = 2_000

  belongs_to :household
  belongs_to :user

  validates :workflow, inclusion: { in: WORKFLOWS }
  validates :status, inclusion: { in: STATUSES }
  validates :attempted, :expected, :actual, presence: true, length: { maximum: MAX_DETAIL_LENGTH }
  validates :screenshot_s3_key, length: { maximum: 1_024 }, allow_blank: true
  validates :screenshot_filename, :screenshot_content_type, length: { maximum: 255 }, allow_blank: true
  validates :screenshot_byte_size, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def screenshot?
    screenshot_s3_key.present?
  end
end
