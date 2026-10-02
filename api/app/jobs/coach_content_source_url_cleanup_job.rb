# frozen_string_literal: true

class CoachContentSourceUrlCleanupJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 5

  def perform(intake_id)
    intake = CoachContentSourceUrlIntake.find_by(id: intake_id)
    return unless intake

    keys = intake.with_lock do
      return if intake.status == "deleted"
      if intake.status == "registered"
        intake.update!(cleanup_attempts: intake.cleanup_attempts + 1)
        next [ intake.staging_s3_key ].compact
      end
      return unless intake.status.in?(%w[cleanup_pending cleanup_failed])

      intake.update!(status: "cleanup_pending", cleanup_attempts: intake.cleanup_attempts + 1)
      [ intake.staging_s3_key, intake.final_s3_key ].compact.uniq
    end
    keys.each { |key| S3Service.delete!(key) }
    intake.with_lock do
      if intake.status == "registered"
        intake.update!(staging_s3_key: nil, cleanup_attempts: 0, error_code: nil)
      else
        intake.update!(status: "failed", staging_s3_key: nil, final_s3_key: nil)
      end
    end
  rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
    persist_failure!(intake) if defined?(intake) && intake
  end

  private

  def persist_failure!(intake)
    attempts = intake.cleanup_attempts
    intake.with_lock do
      return if intake.status == "deleted"
      if intake.status == "registered"
        intake.update!(error_code: "url_staging_cleanup_failed")
      else
        intake.update!(status: "cleanup_failed")
      end
      attempts = intake.cleanup_attempts
    end
    self.class.set(wait: (attempts * 2).minutes).perform_later(intake.id) if attempts < MAX_ATTEMPTS
  end
end
