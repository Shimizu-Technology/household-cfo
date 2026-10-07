module Api
  module V1
    class AuthController < BaseController
      before_action :authenticate_user!

      def me
        workspace = current_user.staff? ? coach_workspace_for_policy : nil
        response.set_header("Cache-Control", "private, no-store")
        render json: { user: current_user.as_api_json(active_coach_workspace: workspace).merge(
          auth_provider: @auth_provider, auth_subject: @auth_subject,
          enterprise_access: EnterpriseAccess.summary_for(current_user)) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Coach workspace not found." }, status: :not_found
      end
    end
  end
end
