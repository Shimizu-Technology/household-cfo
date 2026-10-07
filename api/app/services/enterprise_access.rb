class EnterpriseAccess
  class Denied < StandardError
    attr_reader :code
    def initialize(message = "Your enterprise access is unavailable", code: "enterprise_access_denied")
      @code = code
      super(message)
    end
  end

  def self.summary_for(user)
    return { can_configure: false, organizations: [] } unless user && !user.revoked?
    memberships = EnterpriseMembership.where(user: user, status: "active", it_admin: true, locally_revoked: false).index_by(&:enterprise_organization_id)
    organizations = EnterpriseOrganization.visible_to(user).where(active: true).order(:name)
    { can_configure: user.admin?, organizations: organizations.map { |organization| { id: organization.id, name: organization.name, it_admin: memberships.key?(organization.id) } } }
  end

  def self.authorize!(user:, claims:, client: Enterprise::Client.new, cache: Rails.cache)
    memberships = EnterpriseMembership.where(user: user).includes(:enterprise_organization).to_a
    org_id = claims["org_id"].to_s
    organization = EnterpriseOrganization.find_by(workos_organization_id: org_id) if org_id.present?
    return true if memberships.empty? && !organization
    if organization && memberships.none? { |row| row.enterprise_organization_id == organization.id }
      organization.with_lock do
        unbound = organization.enterprise_memberships.find_by(workos_user_id: claims["sub"], user_id: nil)
        Enterprise::Provisioner.bind_identity!(unbound) if unbound
      end
      memberships = EnterpriseMembership.where(user: user).includes(:enterprise_organization).to_a
    end
    membership = memberships.find { |row| row.enterprise_organization.workos_organization_id == org_id }
    raise Denied, "Sign in through your assigned enterprise organization" unless membership
    raise Denied, "Your enterprise membership is inactive or revoked" unless membership.active_access? && !user.revoked?
    raise Denied, "Enterprise identity does not match this session" unless membership.workos_user_id == claims["sub"]
    proof = Enterprise::ProviderState.verified(membership: membership, claims: claims, client: client, cache: cache)
    membership.reload
    if membership.enterprise_organization.require_sso? && proof[:auth_method] != "sso"
      raise Denied.new("Sign in with your organization’s single sign-on", code: "enterprise_sso_required")
    end
    unless membership.active_access? && !user.reload.revoked? && (membership.it_admin? || Enterprise::Enrollment.allowed_cohort_ids(membership).any?)
      raise Denied, "Your directory assignment is inactive or unassigned"
    end
    true
  end
end
