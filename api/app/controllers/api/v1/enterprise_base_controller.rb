module Api
  module V1
    class EnterpriseBaseController < BaseController
      before_action :authenticate_user!
      after_action :private_response
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Enterprise organization or record not found" }, status: :not_found
      end
      rescue_from EnterpriseAccess::Denied do |error|
        render json: { error: error.message, code: error.code }, status: :forbidden
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end
      rescue_from Enterprise::Client::Unavailable do
        render json: { error: "Enterprise service is temporarily unavailable" }, status: :service_unavailable
      end
      rescue_from ArgumentError do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end

      private

      def enterprise_organization
        return @enterprise_organization if @enterprise_organization
        actor = current_user.reload
        organization = EnterpriseOrganization.visible_to(actor).find(params[:enterprise_organization_id] || params[:id])
        unless actor.admin?
          claims = @authentication_claims || {}
          unless @auth_provider == "workos" && claims["org_id"] == organization.workos_organization_id
            raise EnterpriseAccess::Denied.new("Sign in to this enterprise organization before managing it", code: "enterprise_organization_signin_required")
          end
          EnterpriseAccess.authorize!(user: actor, claims: claims)
        end
        @enterprise_organization = organization
      end

      def with_enterprise_mutation(platform_admin: true, &block)
        Enterprise::MutationAuthority.call(actor: current_user, organization: enterprise_organization,
          platform_admin: platform_admin, claims: @authentication_claims || {}, provider: @auth_provider) do |actor|
          @current_user = actor
          block.call(actor)
        end
      end

      def enterprise_admin!
        raise EnterpriseAccess::Denied, "Platform administrator access required" unless current_user.reload.admin?
      end

      def private_response
        response.set_header("Cache-Control", "private, no-store")
        response.set_header("Referrer-Policy", "no-referrer")
      end

      def enterprise_audit!(action, metadata = {})
        enterprise_organization.enterprise_audit_events.create!(actor_user: current_user, action: action, metadata: metadata)
      end
    end
  end
end
