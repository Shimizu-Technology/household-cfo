# frozen_string_literal: true

class CoachContentSourceUrlIntakeRetentionJob < ApplicationJob
  queue_as :default

  RETENTION_PERIOD = 30.days
  BATCH_SIZE = 100

  def perform
    CoachContentSourceUrlIntake.where(status: %w[failed cleanup_failed])
      .where("COALESCE(completed_at, updated_at) <= ?", RETENTION_PERIOD.ago)
      .find_each(batch_size: BATCH_SIZE) do |intake|
      redact(intake)
    end
  end

  private

  def redact(intake)
    result = intake.request_redaction!
    return unless result == :cleanup_required

    job = CoachContentSourceUrlCleanupJob.perform_later(intake.id)
    raise ActiveJob::EnqueueError, "Secure URL intake cleanup could not be queued" unless job
  rescue ContentSources::Error, ActiveJob::EnqueueError => error
    Rails.logger.warn("[CoachContentSourceUrlIntakeRetentionJob] intake=#{intake.id} error_class=#{error.class}")
  end
end
