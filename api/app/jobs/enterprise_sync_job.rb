class EnterpriseSyncJob < ApplicationJob
  queue_as :default
  retry_on Enterprise::Client::Unavailable, wait: :polynomially_longer, attempts: 5

  def perform
    return unless %w[1 true yes on].include?(ENV.fetch("WORKOS_SYNC_ENABLED", "false").downcase)
    return if ENV["WORKOS_API_KEY"].blank? || !EnterpriseOrganization.exists?
    polling_error = nil
    begin
      Enterprise::EventPoll.call
    rescue Enterprise::Client::Unavailable => error
      polling_error = error
    end
    reconciled_organization_ids = []
    EnterpriseSyncEvent.where(processed_at: nil).order(:occurred_at, :workos_event_id).limit(100).each do |event|
      begin
        Enterprise::EventProcessor.call(event, reconciled_organization_ids: reconciled_organization_ids)
      rescue StandardError
        # Failure class and attempt count are durable on the inbox row. Leave it
        # pending for the next scheduled run while other tenants keep syncing.
        next
      end
    end
    reconcile_error = nil
    # Recovery does not depend on a notification surviving the provider retention window.
    EnterpriseOrganization.where("last_reconciled_at IS NULL OR last_reconciled_at < ?", 1.hour.ago).find_each do |organization|
      begin
        Enterprise::Reconciliation.call(organization)
      rescue StandardError => error
        reconcile_error ||= error
      end
    end
    raise polling_error if polling_error
    raise reconcile_error if reconcile_error
  end
end
