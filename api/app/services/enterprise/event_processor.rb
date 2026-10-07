module Enterprise
  class EventProcessor
    def self.call(event, client: Client.new, reconciled_organization_ids: nil)
      claimed_attempt = nil
      event.with_lock do
        return if event.processed_at
        event.update!(attempts: event.attempts + 1)
        claimed_attempt = event.attempts
      end
      data = event.payload
      org_ids = [ data["organization_id"], data.dig("user", "organization_id"), data.dig("group", "organization_id") ].compact.uniq
      org_ids << data["id"] if event.event_type == "organization.deleted"
      raise EnterpriseAccess::Denied, "Event crosses enterprise organizations" if org_ids.size > 1
      organization = EnterpriseOrganization.find_by(workos_organization_id: org_ids.first)
      if organization
        # Concurrent retries may fetch the same authoritative snapshot. The
        # reconciliation observed_at fence prevents older data overwriting newer
        # state, and the short acknowledgment below records completion once.
        Reconciliation.call(organization, client: client) unless reconciled_organization_ids&.include?(organization.id)
      end
      event.with_lock do
        return if event.processed_at || event.attempts != claimed_attempt
        organization&.enterprise_audit_events&.create!(action: "sync.processed", metadata: { event_id: event.workos_event_id, event_type: event.event_type })
        event.update!(processed_at: Time.current, last_error: nil)
      end
      reconciled_organization_ids << organization.id if reconciled_organization_ids && organization
    rescue StandardError => error
      if claimed_attempt
        event.with_lock { event.update!(last_error: error.class.name) if !event.processed_at && event.attempts == claimed_attempt }
      end
      raise
    end
  end
end
