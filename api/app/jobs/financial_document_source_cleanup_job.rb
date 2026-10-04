class FinancialDocumentSourceCleanupJob < ApplicationJob
  queue_as :default

  class StorageUnavailable < StandardError; end

  def perform(cleanup_id)
    cleanup = FinancialDocumentSourceCleanup.find_by(id: cleanup_id)
    return unless cleanup

    plan = cleanup.claim!
    return unless plan

    raise StorageUnavailable unless S3Service.delete(plan.fetch(:key))

    # Destroy holds the import before FK-nullifying the cleanup. Use that same
    # order so a retry and concurrent removal cannot deadlock.
    ApplicationRecord.transaction do
      FinancialDocumentImport.where(id: cleanup.financial_document_import_id).lock.first
      cleanup.with_lock do
        return unless cleanup.status == "processing" && cleanup.lease_token == plan.fetch(:token)

        # Only clear the source requested for deletion, never a replacement.
        FinancialDocumentImport.where(id: cleanup.financial_document_import_id, s3_key: plan.fetch(:key))
          .where.not(source_deleted_at: nil).update_all(s3_key: nil, updated_at: Time.current)
        cleanup.update!(status: "completed", s3_key: nil, lease_token: nil,
          lease_expires_at: nil, completed_at: Time.current, error_code: nil)
      end
    end
  rescue StorageUnavailable, S3Service::MissingConfigurationError, Aws::S3::Errors::ServiceError,
    Seahorse::Client::NetworkingError, IOError, Timeout::Error => error
    Rails.logger.warn("[DocumentSourceCleanup] cleanup=#{cleanup_id} storage_error_class=#{error.class}")
    persist_failure(cleanup, plan) if cleanup && plan
  end

  private

  def persist_failure(cleanup, plan)
    cleanup.with_lock do
      return unless cleanup.status == "processing" && cleanup.lease_token == plan.fetch(:token)

      delay = [ 2**[ cleanup.attempts, 10 ].min, 60 ].min.minutes
      cleanup.update!(status: "failed", error_code: "storage_unavailable", lease_token: nil,
        lease_expires_at: nil, next_attempt_at: delay.from_now)
      if cleanup.attempts >= FinancialDocumentSourceCleanup::ALERT_AFTER_ATTEMPTS
        # Keep retrying the privacy obligation; do not abandon its storage key.
        Rails.logger.error("[DocumentSourceCleanup] cleanup=#{cleanup.id} stalled_cleanup attempts=#{cleanup.attempts}")
      end
    end
    cleanup.enqueue_retry
  end
end
