class PlaidStaleItemRecoveryJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 24.hours
  INITIAL_SYNC_GRACE_PERIOD = 1.hour

  def perform
    stale_items.find_each do |item|
      PlaidTransactionSyncJob.perform_later(item.id)
    end
  end

  private

  def stale_items
    cutoff = Time.current - STALE_AFTER
    initial_cutoff = Time.current - INITIAL_SYNC_GRACE_PERIOD

    PlaidItem.where(status: "active").where(
      "last_successful_update_at < :cutoff OR (last_successful_update_at IS NULL AND created_at < :initial_cutoff)",
      cutoff: cutoff,
      initial_cutoff: initial_cutoff
    )
  end
end
