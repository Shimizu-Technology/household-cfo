# frozen_string_literal: true

class CoachContentSourceUploadExpiryJob < ApplicationJob
  queue_as :default
  retry_on Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError, wait: :polynomially_longer, attempts: 5 do |job, _error|
    source = CoachContentSource.find_by(id: job.arguments.first)
    source&.with_lock do
      next unless source.status == "upload_cleanup"

      source.update!(
        status: "upload_cleanup_failed",
        error_code: "upload_cleanup_failed",
        error_message: "Private storage cleanup needs an administrator to retry it."
      )
    end
  end

  def perform(source_id, admin_retry: false)
    source = CoachContentSource.find_by(id: source_id)
    return unless source

    key = source.with_lock do
      if source.status == "upload_cleanup_failed"
        next unless admin_retry

        source.update!(status: "upload_cleanup", error_code: nil, error_message: nil)
      elsif source.status.in?(%w[uploading verifying])
        next unless source.created_at <= 45.minutes.ago
        source.update!(status: "upload_cleanup")
      end
      next unless source.status == "upload_cleanup"

      source.s3_key
    end
    return if key.blank?

    S3Service.delete!(key)
    source.with_lock { source.destroy! if source.status == "upload_cleanup" && source.s3_key == key }
  end
end
