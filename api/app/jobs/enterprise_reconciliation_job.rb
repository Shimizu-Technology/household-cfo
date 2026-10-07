class EnterpriseReconciliationJob < ApplicationJob
  queue_as :default
  retry_on Enterprise::Client::Unavailable, wait: :polynomially_longer, attempts: 5

  def perform(organization_id)
    Enterprise::Reconciliation.call(EnterpriseOrganization.find(organization_id))
  end
end
