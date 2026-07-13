class PlaidTransactionSyncJob < ApplicationJob
  queue_as :default

  def perform(plaid_item_id)
    item = PlaidItem.connected.find_by(id: plaid_item_id)
    PlaidIntegration::TransactionSync.new(item).call if item
  rescue PlaidIntegration::Error => e
    Rails.logger.warn("Plaid transaction sync failed for item record #{plaid_item_id}: #{e.code || 'request_failed'}")
  end
end
