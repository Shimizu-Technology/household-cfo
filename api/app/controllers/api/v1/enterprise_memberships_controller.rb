module Api
  module V1
    class EnterpriseMembershipsController < EnterpriseBaseController
      def index
        render json: { memberships: enterprise_organization.enterprise_memberships.includes(:user).order(:id).map(&:as_api_json) }
      end

      def update
        with_enterprise_mutation do
          membership = enterprise_organization.enterprise_memberships.find(params[:id])
          attributes = params.require(:membership).permit(:it_admin, :locally_revoked)
          if ActiveModel::Type::Boolean.new.cast(attributes[:it_admin]) && (membership.status != "active" || membership.user.nil?)
            raise Enterprise::InvalidRequest, "Only an admitted active user can administer enterprise configuration"
          end
          membership.update!(attributes)
          Enterprise::Enrollment.reconcile!(membership)
          enterprise_audit!("membership.updated", membership_id: membership.id, it_admin: membership.it_admin, locally_revoked: membership.locally_revoked)
          render json: { membership: membership.as_api_json }
        end
      end
    end
  end
end
