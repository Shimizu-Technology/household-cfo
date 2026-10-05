# Primary-database extraction intent. Queue admission and provider work are leased,
# so neither a separate queue commit nor a killed worker can erase the intent.
class FinancialDocumentExtractionDispatch < ApplicationRecord
  STATUSES = %w[pending enqueued processing completed cancelled].freeze
  LEASE_DURATION = 15.minutes

  belongs_to :financial_document_import, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :source_fingerprint, :next_attempt_at, presence: true
  validates :generation, numericality: { only_integer: true, greater_than: 0 }
  validates :enqueue_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :due, -> {
    where(status: "pending", next_attempt_at: ..Time.current)
      .or(where(status: %w[enqueued processing], lease_expires_at: ..Time.current))
  }

  def self.fingerprint(document_import)
    Digest::SHA256.hexdigest([ document_import.s3_key, document_import.checksum_sha256,
      document_import.content_type, document_import.byte_size, document_import.filename ].to_json)
  end

  # Call inside the primary transaction registering the source or manual retry.
  # Import -> dispatch is the lock order throughout admission and execution.
  def self.request!(document_import, restart: false)
    document_import.with_lock do
      dispatch = find_or_initialize_by(financial_document_import_id: document_import.id)
      source_fingerprint = fingerprint(document_import)
      if dispatch.new_record? || restart || dispatch.source_fingerprint != source_fingerprint
        dispatch.generation += 1 unless dispatch.new_record?
        dispatch.assign_attributes(status: "pending", source_fingerprint: source_fingerprint,
          next_attempt_at: Time.current, lease_expires_at: nil, lease_token: nil,
          enqueue_attempts: 0, error_code: nil)
        dispatch.save!
      end
      dispatch
    end
  end

  # Safe after the primary commit. Admission failure returns normally; the sweep
  # retries the stored intent. The token prevents late admission callbacks from
  # changing a worker's processing lease or a newer generation.
  def enqueue_retry
    document_import = financial_document_import
    return cancel!("import_removed") unless document_import

    claim = nil
    document_import.with_lock do
      with_lock do
        return if status.in?(%w[completed cancelled])
        return cancel!("source_unavailable") unless document_import.source_available?
        return cancel!("import_ineligible") unless document_import.status.in?(%w[uploaded processing])
        return cancel!("source_changed") if source_fingerprint != self.class.fingerprint(document_import)
        return if status == "pending" && next_attempt_at > Time.current
        return if status.in?(%w[enqueued processing]) && lease_expires_at && lease_expires_at > Time.current

        token = SecureRandom.uuid
        update!(status: "enqueued", lease_token: token, lease_expires_at: LEASE_DURATION.from_now,
          next_attempt_at: LEASE_DURATION.from_now, enqueue_attempts: enqueue_attempts + 1, error_code: nil)
        claim = [ generation, token ]
      end
    end
    job = FinancialDocumentExtractionJob.perform_later(document_import.id, id, claim.first)
    admission_failed!(claim, "enqueue_rejected") unless job
    job
  rescue StandardError => error
    Rails.logger.warn("[DocumentExtractionDispatch] dispatch=#{id} enqueue_error_class=#{error.class}")
    admission_failed!(claim, "enqueue_unavailable") if claim
    nil
  end

  def cancel!(code)
    transaction do
      update!(status: "cancelled", lease_token: nil, lease_expires_at: nil, error_code: code)
      document_import = financial_document_import
      if document_import && document_import.status.in?(%w[uploaded processing])
        message = code == "source_changed" ? "The document source changed before extraction completed. Reprocess the current source." : "Document source is no longer available for extraction."
        document_import.update!(status: "failed", extraction_error: message, processed_at: Time.current)
      end
    end
    nil
  end

  private

  def admission_failed!(claim, code)
    with_lock do
      return unless status == "enqueued" && generation == claim.first && lease_token == claim.last

      delay = [ 30 * (2**[ enqueue_attempts - 1, 7 ].min), 1.hour.to_i ].min.seconds
      update!(status: "pending", lease_token: nil, lease_expires_at: nil,
        next_attempt_at: delay.from_now, error_code: code)
    end
  end
end
