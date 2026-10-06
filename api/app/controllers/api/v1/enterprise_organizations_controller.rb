module Api
  module V1
    class EnterpriseOrganizationsController < EnterpriseBaseController
      def index
        render json: { enterprise_organizations: EnterpriseOrganization.visible_to(current_user).order(:name).map(&:as_api_json) }
      end

      def show
        render json: { enterprise_organization: enterprise_organization.as_api_json,
          group_mappings: enterprise_organization.enterprise_group_mappings.map(&:as_api_json),
          eligible_cohorts: current_user.admin? ? enterprise_organization.coach_workspace.cohorts.order(:name).map { |cohort| { id: cohort.id, name: cohort.name } } : [],
          can_manage_memberships: current_user.admin? }
      end

      def create
        enterprise_admin!
        attributes = params.require(:enterprise_organization).permit(:name, :coach_workspace_id, :workos_organization_id, :require_sso)
        organization = EnterpriseOrganization.create!(attributes)
        organization.enterprise_audit_events.create!(actor_user: current_user, action: "organization.created")
        render json: { enterprise_organization: organization.as_api_json }, status: :created
      end

      def update
        enterprise_admin!
        enterprise_organization.with_lock do
          enterprise_organization.update!(params.require(:enterprise_organization).permit(:name, :active, :require_sso, :directory_provisioning_enabled))
          enterprise_organization.enterprise_memberships.each { |membership| Enterprise::Enrollment.reconcile!(membership) }
          enterprise_audit!("organization.updated")
        end
        render json: { enterprise_organization: enterprise_organization.as_api_json }
      end

      def portal
        result = Enterprise::Portal.call(organization: enterprise_organization, user: current_user, intent: params[:intent], return_url: params[:return_url])
        render json: result
      end

      def reconcile
        EnterpriseReconciliationJob.perform_later(enterprise_organization.id)
        enterprise_audit!("reconciliation.requested")
        render json: { queued: true }, status: :accepted
      end

      def audit
        events = enterprise_organization.enterprise_audit_events.order(id: :desc).limit(100)
        render json: { audit_events: events.map { |event| { id: event.id, action: event.action, actor_user_id: event.actor_user_id, metadata: event.metadata, created_at: event.created_at } } }
      end
    end
  end
end
