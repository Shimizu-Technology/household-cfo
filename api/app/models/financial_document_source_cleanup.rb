# A primary-database outbox: it survives deleting its import and a queue outage.
class FinancialDocumentSourceCleanup < ApplicationRecord
  STATUSES = %w[pending processing failed completed].freeze
  LEASE_DURATION = 10.minutes

  belongs_to :financial_document_import, optional: true
  belongs_to :household, optional: true
  belongs_to :requested_by_user, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :s3_key, presence: true, unless: -> { status == "completed" }
  validates :s3_key, length: { maximum: 1024 }, allow_nil: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :next_attempt_at, presence: true

  scope :due, -> {
    where(status: %w[pending failed]).where(next_attempt_at: ..Time.current)
      .or(where(status: "processing").where(lease_expires_at: ..Time.current))
  }

  def self.request!(document_import, user:)
    key = document_import.s3_key
    return if key.blank?

    find_or_create_by!(s3_key: key) do |cleanup|
      cleanup.financial_document_import = document_import
      cleanup.household = document_import.household
      cleanup.requested_by_user = user
      cleanup.next_attempt_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(s3_key: key)
  end

  def claim!
    with_lock do
      return if status == "completed"
      return if status == "processing" && lease_expires_at && lease_expires_at > Time.current
      return if status != "processing" && next_attempt_at > Time.current

      token = SecureRandom.uuid
      update!(status: "processing", attempts: attempts + 1, lease_token: token,
        lease_expires_at: LEASE_DURATION.from_now, error_code: nil)
      { key: s3_key, token: token }
    end
  end

  # Failed queue admission is recoverable from the primary outbox, not a lost job.
  def enqueue_retry
    job = FinancialDocumentSourceCleanupJob.set(wait_until: next_attempt_at).perform_later(id)
    Rails.logger.warn("[DocumentSourceCleanup] cleanup=#{id} enqueue_rejected") unless job
    job
  rescue StandardError => error
    Rails.logger.warn("[DocumentSourceCleanup] cleanup=#{id} enqueue_error_class=#{error.class}")
    nil
  end
end
