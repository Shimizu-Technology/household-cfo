module Api
  module V1
    class EnterpriseOrganizationsController < EnterpriseBaseController
      def index
        actor = current_user.reload
        organizations = EnterpriseOrganization.visible_to(actor).order(:name)
        rows = organizations.map do |organization|
          actor.admin? ? organization.as_api_json : { id: organization.id, name: organization.name, workos_organization_id: organization.workos_organization_id }
        end
        render json: { enterprise_organizations: rows }
      end

      def show
        render json: { enterprise_organization: enterprise_organization.as_api_json,
          group_mappings: enterprise_organization.enterprise_group_mappings.map(&:as_api_json),
          eligible_cohorts: current_user.admin? ? enterprise_organization.coach_workspace.cohorts.order(:name).map { |cohort| { id: cohort.id, name: cohort.name } } : [],
          can_manage_memberships: current_user.admin? }
      end

      def create
        Enterprise::MutationAuthority.call(actor: current_user, claims: @authentication_claims || {}, provider: @auth_provider) do |actor|
          attributes = params.require(:enterprise_organization).permit(:name, :coach_workspace_id, :workos_organization_id, :require_sso)
          organization = EnterpriseOrganization.create!(attributes)
          organization.enterprise_audit_events.create!(actor_user: actor, action: "organization.created")
          render json: { enterprise_organization: organization.as_api_json }, status: :created
        end
      end

      def update
        with_enterprise_mutation do
          enterprise_organization.update!(params.require(:enterprise_organization).permit(:name, :active, :require_sso, :directory_provisioning_enabled))
          enterprise_organization.enterprise_memberships.each { |membership| Enterprise::Enrollment.reconcile!(membership) }
          enterprise_audit!("organization.updated")
        end
        render json: { enterprise_organization: enterprise_organization.as_api_json }
      end

      def portal
        result = Enterprise::Portal.call(organization: enterprise_organization, user: current_user, intent: params[:intent], return_url: params[:return_url], claims: @authentication_claims || {}, provider: @auth_provider)
        render json: result
      end

      def reconcile
        queued = false
        with_enterprise_mutation(platform_admin: false) do
          organization = enterprise_organization
          recent = organization.last_reconciled_at && organization.last_reconciled_at > 1.minute.ago
          requested = organization.enterprise_audit_events.where(action: "reconciliation.requested").where("created_at > ?", 1.minute.ago).exists?
          unless recent || requested
            # The organization lock serializes requests; a bounded reservation
            # also throttles retries before the queued job finishes.
            job = EnterpriseReconciliationJob.perform_later(organization.id)
            raise Enterprise::Client::Unavailable, "Enterprise reconciliation could not be queued" unless job
            enterprise_audit!("reconciliation.requested")
            queued = true
          end
        end
        render json: { queued: queued }, status: :accepted
      end

      def audit
        events = enterprise_organization.enterprise_audit_events.order(id: :desc).limit(100)
        render json: { audit_events: events.map { |event| { id: event.id, action: event.action, actor_user_id: event.actor_user_id, metadata: event.metadata, created_at: event.created_at } } }
      end
    end
  end
end
