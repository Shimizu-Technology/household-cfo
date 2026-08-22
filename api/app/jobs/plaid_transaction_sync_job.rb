class PlaidTransactionSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(plaid_item_id) { plaid_item_id }, duration: 10.minutes

  def perform(plaid_item_id)
    item = PlaidItem.syncable.find_by(id: plaid_item_id)
    PlaidIntegration::TransactionSync.new(item).call if item
  rescue PlaidIntegration::Error => e
    Rails.logger.warn("Plaid transaction sync failed for item record #{plaid_item_id}: #{e.code || 'request_failed'}")
    Rails.error.report(e, handled: true, context: { plaid_item_record_id: plaid_item_id, plaid_error_code: e.code })
  end
end
