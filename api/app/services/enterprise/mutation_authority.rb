module Enterprise
  class MutationAuthority
    def self.call(actor:, organization: nil, platform_admin: true, claims: {}, provider: nil, &block)
      operation = lambda do
        User.transaction do
          persisted_actor = User.lock("FOR NO KEY UPDATE").find(actor.id)
          unless persisted_actor.invitation_accepted? && !persisted_actor.revoked?
            raise EnterpriseAccess::Denied, "This account is no longer authorized"
          end
          memberships = EnterpriseMembership.where(user: persisted_actor).includes(:enterprise_organization).to_a
          if memberships.any?
            source = memberships.find { |membership| membership.enterprise_organization.workos_organization_id == claims["org_id"] }
            unless source&.active_access? && source.workos_user_id == claims["sub"]
              raise EnterpriseAccess::Denied, "Your enterprise membership is inactive or revoked"
            end
            if source.enterprise_organization.require_sso? && provider != "workos"
              raise EnterpriseAccess::Denied.new("Sign in with your organization’s single sign-on", code: "enterprise_sso_required")
            end
          end
          if platform_admin
            raise EnterpriseAccess::Denied, "Platform administrator access required" unless persisted_actor.admin?
          elsif !persisted_actor.admin?
            it = organization&.enterprise_memberships&.find_by(user: persisted_actor, status: "active", it_admin: true, locally_revoked: false)
            unless organization&.active? && it && claims["org_id"] == organization.workos_organization_id && provider == "workos"
              raise EnterpriseAccess::Denied, "Enterprise IT administration access required"
            end
          end
          block.call(persisted_actor)
        end
      end
      organization ? organization.with_lock(&operation) : operation.call
    end
  end
end
