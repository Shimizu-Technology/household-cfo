module Enterprise
  class Admission
    def self.resolve!(subject:, claims:, profile:, client: Client.new)
      organization = EnterpriseOrganization.find_by(workos_organization_id: claims["org_id"], active: true)
      raise EnterpriseAccess::Denied, "Your organization is not enabled for enterprise admission" unless organization
      raise EnterpriseAccess::Denied, "Directory provisioning is awaiting vendor enablement" unless organization.directory_provisioning_enabled?
      raise EnterpriseAccess::Denied, "Enterprise identity does not match this session" unless subject == claims["sub"]
      profile = profile.to_h.stringify_keys
      observed_at = Time.current
      directory_id = organization.directory_id
      provider = client.memberships(organization_id: organization.workos_organization_id, user_id: subject).find do |row|
        row["user_id"] == subject && row["organization_id"] == organization.workos_organization_id && row["status"] == "active"
      end
      raise EnterpriseAccess::Denied, "An active enterprise membership is required" unless provider
      session = client.sessions(subject).find { |row| row["id"] == claims["sid"] }
      valid_session = session && session["status"] == "active" && session["user_id"] == subject && session["organization_id"] == organization.workos_organization_id
      raise EnterpriseAccess::Denied, "Your enterprise session is no longer active" unless valid_session
      raise EnterpriseAccess::Denied, "Your enterprise directory is not linked" unless directory_id.present? && organization.directory_state == "linked"
      begin
        directory = client.directory(directory_id)
      rescue Client::NotFound
        raise EnterpriseAccess::Denied, "Your enterprise directory is unavailable"
      end
      unless directory["id"] == directory_id && directory["organization_id"] == organization.workos_organization_id && directory["state"] == "linked"
        raise EnterpriseAccess::Denied, "Your enterprise directory is not linked"
      end
      snapshot = Provisioner.directory_snapshot(organization, profile, client: client, directory_id: directory_id)
      user = organization.with_lock do
        raise EnterpriseAccess::Denied, "Your organization is not enabled for enterprise admission" unless organization.active? && organization.directory_provisioning_enabled?
        raise EnterpriseAccess::Denied, "Your enterprise directory is not linked" unless organization.directory_id == directory_id && organization.directory_state == "linked"
        if organization.require_sso? && session["auth_method"] != "sso"
          raise EnterpriseAccess::Denied.new("Sign in with your organization’s single sign-on", code: "enterprise_sso_required")
        end
        existing = organization.enterprise_memberships.find_by(workos_user_id: subject)
        raise EnterpriseAccess::Denied, "Your enterprise membership is inactive or revoked" if existing&.locally_revoked? || existing&.user&.revoked?
        if (organization.last_reconciled_at && organization.last_reconciled_at > observed_at) ||
            (existing&.provider_updated_at && existing.provider_updated_at > observed_at) || Time.current - observed_at >= ProviderState::TTL
          raise Client::Unavailable, "Enterprise admission verification was superseded; retry"
        end
        membership = Provisioner.membership!(organization, provider, observed_at: observed_at)
        Provisioner.apply_directory_snapshot!(organization, membership, snapshot, observed_at: observed_at)
        admitted = materialize!(membership, profile)
        raise EnterpriseAccess::Denied, "An active mapped directory group is required" unless admitted && (membership.it_admin? || Enrollment.allowed_cohort_ids(membership).any?)
        admitted
      end
      # Recheck current session and assignment proof without holding the cohort's
      # organization lock or a database transaction across provider requests.
      EnterpriseAccess.authorize!(user: user, claims: claims, client: client)
      user
    end

    def self.materialize!(membership, profile)
      return membership.user if membership.user
      return nil unless membership.active_access? && membership.enterprise_organization.directory_provisioning_enabled?
      return nil if Enrollment.allowed_cohort_ids(membership).empty?
      raise EnterpriseAccess::Denied, "A verified WorkOS email is required" unless profile["id"] == membership.workos_user_id && profile["email_verified"] == true
      subject = membership.workos_user_id
      identity = AuthenticationIdentity.find_by(provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
      user = identity&.user
      unless user
        email = profile["email"].to_s.strip.downcase
        raise EnterpriseAccess::Denied, "Explicit identity mapping is required for this existing account" if email.blank? || User.where("LOWER(email) = ?", email).exists?
        user = User.create!(clerk_id: "workos_#{subject}", email: email, first_name: profile["first_name"], last_name: profile["last_name"], role: "participant", invitation_status: "accepted", accepted_at: Time.current)
        AuthenticationIdentity.create!(user: user, provider: "workos", issuer: WorkosAuth.issuer, subject: subject)
      end
      raise EnterpriseAccess::Denied, "This account is revoked" if user.revoked?
      membership.update!(user: user)
      Enrollment.reconcile!(membership)
      user
    end
  end
end
