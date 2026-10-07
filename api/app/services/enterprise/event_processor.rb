module Enterprise
  class EventProcessor
    def self.call(event, client: Client.new, reconciled_organization_ids: nil)
      reconciled_id = nil
      event.with_lock do
        return if event.processed_at
        data = event.payload
        org_ids = [ data["organization_id"], data.dig("user", "organization_id"), data.dig("group", "organization_id") ].compact.uniq
        org_ids << data["id"] if event.event_type == "organization.deleted"
        raise EnterpriseAccess::Denied, "Event crosses enterprise organizations" if org_ids.size > 1
        organization = EnterpriseOrganization.find_by(workos_organization_id: org_ids.first)
        if organization
          # Treat events as change notifications. Read the authoritative current
          # snapshot, so a replay or late active event cannot undo deprovisioning.
          Reconciliation.call(organization, client: client) unless reconciled_organization_ids&.include?(organization.id)
          reconciled_id = organization.id
          organization.enterprise_audit_events.create!(action: "sync.processed", metadata: { event_id: event.workos_event_id, event_type: event.event_type })
        end
        event.update!(processed_at: Time.current, attempts: event.attempts + 1, last_error: nil)
      end
      reconciled_organization_ids << reconciled_id if reconciled_organization_ids && reconciled_id
    rescue StandardError => error
      event.with_lock { event.update!(attempts: event.attempts + 1, last_error: error.class.name) }
      raise
    end
  end
end
