module Api
  module V1
    class SetupSupportRequestsController < BaseController
      before_action :authenticate_user!
      before_action { response.set_header("Cache-Control", "private, no-store") }
      rescue_from SetupHelp::Error do |error|
        render json: { errors: [ error.message ], code: "setup_help_invalid" }, status: :unprocessable_entity
      end
      rescue_from SetupHelp::Denied do |error|
        render json: { errors: [ error.message ], code: "setup_help_denied" }, status: :forbidden
      end
      rescue_from SetupHelp::Stale, SetupHelp::Conflict do |error|
        render json: { errors: [ error.message ], code: "setup_help_stale" }, status: :conflict
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Setup support request not found for this account and program." ] }, status: :not_found
      end
      def index = render(json: staff.list(cohort_id: params[:cohort_id], cursor: params[:cursor], limit: params[:limit]))
      def triage = transition("triage")
      def prepare = transition("prepare")
      def decline = transition("decline")
      private
      def transition(action) = render(json: staff.transition(id: params[:id], action: action, expected_lock_version: params[:expected_lock_version]))
      def staff = SetupHelp::Staff.new(user: current_user, workspace_id: request.headers["X-Coach-Workspace-Id"].presence)
    end
  end
end
