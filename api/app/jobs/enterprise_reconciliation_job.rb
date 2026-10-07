class EnterpriseReconciliationJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(organization_id) { organization_id }, duration: 10.minutes
  retry_on Enterprise::Client::Unavailable, wait: :polynomially_longer, attempts: 5

  def perform(organization_id)
    organization = EnterpriseOrganization.find(organization_id)
    return if organization.last_reconciled_at && organization.last_reconciled_at > 1.minute.ago
    Enterprise::Reconciliation.call(organization)
  end
end
