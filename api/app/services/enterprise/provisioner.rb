module Enterprise
  class Provisioner
    def self.membership!(organization, data, observed_at: nil, deleted: false)
      raise EnterpriseAccess::Denied, "Enterprise organization mismatch" unless data["organization_id"] == organization.workos_organization_id
      membership = organization.enterprise_memberships.find_or_initialize_by(workos_user_id: data.fetch("user_id"))
      timestamp = observed_at || Time.iso8601(data.fetch("updated_at"))
      if membership.provider_updated_at && membership.provider_updated_at >= timestamp
        bind_identity!(membership)
        Enrollment.reconcile!(membership)
        return membership
      end
      status = deleted ? "inactive" : data.fetch("status")
      membership.it_admin = false if status != "active"
      membership.locally_revoked = true if status != "active" && membership.user&.staff?
      membership.assign_attributes(status: status, workos_membership_id: data.fetch("id"), provider_updated_at: timestamp)
      # Only an already verified subject binding may attach an existing local user.
      membership.save!
      bind_identity!(membership)
      Enrollment.reconcile!(membership)
      membership
    end

    def self.bind_identity!(membership)
      return membership if membership.user
      identity = AuthenticationIdentity.find_by(provider: "workos", issuer: WorkosAuth.issuer, subject: membership.workos_user_id)
      if identity
        attributes = { user: identity.user }
        attributes[:locally_revoked] = true if membership.status != "active" && identity.user.staff?
        membership.update!(attributes)
      end
      membership
    end

    def self.directory_user!(organization, data, observed_at: nil, deleted: false)
      validate_directory!(organization, data)
      row = organization.enterprise_directory_users.find_or_initialize_by(workos_directory_user_id: data.fetch("id"))
      timestamp = observed_at || Time.iso8601(data.fetch("updated_at"))
      return row if row.provider_updated_at && row.provider_updated_at >= timestamp
      row.assign_attributes(email: data["email"].to_s.strip.downcase, state: deleted ? "inactive" : data.fetch("state"), provider_updated_at: timestamp)
      row.save!
      if row.state != "active" && row.enterprise_membership
        row.enterprise_membership.update!(status: "inactive", it_admin: false, locally_revoked: row.enterprise_membership.locally_revoked? || row.enterprise_membership.user&.staff? || false)
        Enrollment.reconcile!(row.enterprise_membership)
      end
      row
    end

    def self.directory_snapshot(organization, profile, client: Client.new, directory_id: organization.directory_id)
      return [] if directory_id.blank?
      raise EnterpriseAccess::Denied, "A directory email is required" if profile["email"].blank?
      client.directory_users(directory_id: directory_id, email: profile.fetch("email")).map do |data|
        validate_directory!(organization, data, directory_id: directory_id)
        raise EnterpriseAccess::Denied, "Directory email mismatch" unless data["email"].to_s.strip.downcase == profile["email"].to_s.strip.downcase
        groups = client.directory_groups(directory_id: directory_id, user_id: data.fetch("id"))
        groups.each { |group| validate_directory!(organization, group, directory_id: directory_id) }
        { data: data, group_ids: groups.map { |group| group.fetch("id") } }
      end
    end

    def self.refresh_directory_for!(organization, membership, profile, client: Client.new, observed_at: Time.current)
      snapshot = directory_snapshot(organization, profile, client: client)
      apply_directory_snapshot!(organization, membership, snapshot, observed_at: observed_at)
    end

    def self.apply_directory_snapshot!(organization, membership, snapshot, observed_at:)
      seen = snapshot.map { |item| item[:data].fetch("id") }
      snapshot.each do |item|
        data = item[:data]
        row = organization.enterprise_directory_users.find_by(workos_directory_user_id: data.fetch("id"))
        next if row&.provider_updated_at && row.provider_updated_at > observed_at
        row = directory_user!(organization, data, observed_at: observed_at)
        raise EnterpriseAccess::Denied, "Directory identity is already assigned" if row.enterprise_membership_id && row.enterprise_membership_id != membership.id
        row.update!(enterprise_membership: membership)
        group_ids = item[:group_ids]
        fresh(row.enterprise_directory_group_memberships.where.not(workos_group_id: group_ids), observed_at).update_all(active: false, provider_updated_at: observed_at)
        group_ids.each do |group_id|
          edge = row.enterprise_directory_group_memberships.find_or_initialize_by(workos_group_id: group_id)
          next if edge.provider_updated_at && edge.provider_updated_at > observed_at
          edge.update!(active: true, provider_updated_at: observed_at)
        end
      end
      fresh(membership.enterprise_directory_users.where.not(workos_directory_user_id: seen), observed_at).update_all(state: "inactive", provider_updated_at: observed_at)
      Enrollment.reconcile!(membership)
    end

    def self.fresh(scope, observed_at)
      scope.where("provider_updated_at IS NULL OR provider_updated_at <= ?", observed_at)
    end

    def self.validate_directory!(organization, data, directory_id: organization.directory_id)
      valid = data["organization_id"] == organization.workos_organization_id && directory_id.present? && data["directory_id"] == directory_id
      raise EnterpriseAccess::Denied, "Enterprise directory mismatch" unless valid
    end
  end
end
