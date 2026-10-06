module Enterprise
  class Reconciliation
    def self.call(organization, client: Client.new)
      observed_at = Time.current
      snapshot = fetch_snapshot(organization, client: client)
      organization.with_lock do
        return if organization.last_reconciled_at && organization.last_reconciled_at > observed_at
        if snapshot[:deleted]
          organization.update!(active: false, last_reconciled_at: observed_at, last_sync_error: nil)
          deactivate_missing!(organization, [], observed_at)
          return
        end
        directory = snapshot[:directory]
        organization.update!(directory_id: directory&.fetch("id"), directory_state: directory&.fetch("state") || "unconfigured",
          connection_state: snapshot[:connection_state])
        seen = []
        snapshot[:memberships].each do |item|
          membership = Provisioner.membership!(organization, item[:provider], observed_at: observed_at)
          seen << membership.id
          next unless item[:profile]
          Provisioner.apply_directory_snapshot!(organization, membership, item[:directory_users], observed_at: observed_at)
          begin
            Admission.materialize!(membership, item[:profile])
          rescue EnterpriseAccess::Denied => error
            organization.enterprise_audit_events.create!(action: "admission.blocked", metadata: { membership_id: membership.id, code: error.code })
          end
          Enrollment.reconcile!(membership)
        end
        deactivate_missing!(organization, seen, observed_at)
        if organization.directory_id.blank?
          Provisioner.fresh(organization.enterprise_directory_users, observed_at).update_all(state: "inactive", provider_updated_at: observed_at)
          organization.enterprise_memberships.each { |membership| Enrollment.reconcile!(membership) }
        end
        organization.update!(last_reconciled_at: observed_at, last_sync_error: nil)
      end
    rescue StandardError => error
      organization.update_columns(last_sync_error: error.class.name, updated_at: Time.current)
      raise
    end

    def self.fetch_snapshot(organization, client:)
      begin
        client.request(:get, "/organizations/#{client.safe_id(organization.workos_organization_id)}")
      rescue Client::NotFound
        return { deleted: true }
      end
      directories = client.list("/directories", organization_id: organization.workos_organization_id)
      connections = client.list("/connections", organization_id: organization.workos_organization_id)
      unless (directories + connections).all? { |row| row["organization_id"] == organization.workos_organization_id }
        raise EnterpriseAccess::Denied, "Enterprise organization mismatch"
      end
      directory = directories.find { |row| row["id"] == organization.directory_id } || (directories.one? ? directories.first : nil)
      memberships = client.memberships(organization_id: organization.workos_organization_id).map do |provider|
        item = { provider: provider }
        if provider["status"] == "active"
          profile = client.profile(provider.fetch("user_id"))
          raise EnterpriseAccess::Denied, "Enterprise identity mismatch" unless profile["id"] == provider["user_id"]
          item[:profile] = profile
          item[:directory_users] = Provisioner.directory_snapshot(organization, profile, client: client, directory_id: directory&.fetch("id"))
        end
        item
      end
      { directory: directory, connection_state: connections.any? { |row| row["state"] == "active" } ? "active" : "unconfigured", memberships: memberships }
    end

    def self.deactivate_missing!(organization, seen, observed_at)
      Provisioner.fresh(organization.enterprise_memberships.where.not(id: seen), observed_at).each do |membership|
        membership.update!(status: "inactive", it_admin: false, locally_revoked: membership.locally_revoked? || membership.user&.staff? || false, provider_updated_at: observed_at)
        Enrollment.reconcile!(membership)
      end
    end
  end
end
