module Enterprise
  class Admission
    def self.resolve!(subject:, claims:, profile:, client: Client.new)
      organization = EnterpriseOrganization.find_by(workos_organization_id: claims["org_id"], active: true)
      raise EnterpriseAccess::Denied, "Your organization is not enabled for enterprise admission" unless organization
      raise EnterpriseAccess::Denied, "Directory provisioning is awaiting vendor enablement" unless organization.directory_provisioning_enabled?
      raise EnterpriseAccess::Denied, "Enterprise identity does not match this session" unless subject == claims["sub"]
      organization.with_lock do
        provider = client.memberships(organization_id: organization.workos_organization_id, user_id: subject).find do |row|
          row["user_id"] == subject && row["organization_id"] == organization.workos_organization_id && row["status"] == "active"
        end
        raise EnterpriseAccess::Denied, "An active enterprise membership is required" unless provider
        membership = Provisioner.membership!(organization, provider)
        Provisioner.refresh_directory_for!(organization, membership, profile.to_h.stringify_keys, client: client)
        user = materialize!(membership, profile.to_h.stringify_keys)
        raise EnterpriseAccess::Denied, "An active mapped directory group is required" unless user
        EnterpriseAccess.authorize!(user: user, claims: claims, client: client)
        user
      end
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
