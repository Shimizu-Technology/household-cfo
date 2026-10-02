# frozen_string_literal: true

class CoachContentSourceUrlIntakeRecoveryJob < ApplicationJob
  queue_as :default

  RECOVERABLE_STATUSES = %w[queued fetching staged registering cleanup_pending].freeze
  STALE_AFTER = CoachContentSourceUrlIntakeJob::STALE_BOUNDARY_AFTER
  BATCH_SIZE = 100

  def perform
    CoachContentSourceUrlIntake.where(status: RECOVERABLE_STATUSES)
      .where(updated_at: ..STALE_AFTER.ago).find_each(batch_size: BATCH_SIZE) do |intake|
      enqueue_recovery(intake)
    end
  end

  private

  def enqueue_recovery(intake)
    job = if intake.status == "cleanup_pending"
      CoachContentSourceUrlCleanupJob.perform_later(intake.id)
    elsif intake.status == "queued"
      CoachContentSourceUrlIntakeJob.perform_later(intake.id)
    else
      CoachContentSourceUrlIntakeJob.perform_later(intake.id, recovery: true)
    end
    raise ActiveJob::EnqueueError, "Secure URL intake recovery could not be queued" unless job
  rescue ActiveJob::EnqueueError => error
    Rails.logger.warn("[CoachContentSourceUrlIntakeRecoveryJob] intake=#{intake.id} enqueue_error=#{error.class}")
  end
end
