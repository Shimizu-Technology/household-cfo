module Api
  module V1
    class SetupHelpController < BaseController
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
      rescue_from HouseholdFinance::FinancialRestart::Flow::Error do |error|
        render json: { errors: [ error.message ], code: "setup_help_invalid" }, status: :unprocessable_entity
      end
      rescue_from HouseholdFinance::FinancialRestart::Flow::StaleReview do |error|
        render json: { errors: [ error.message ], code: "financial_restart_review_stale" }, status: :conflict
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Setup help review not found for this account and program." ] }, status: :not_found
      end

      def show = render(json: { setup_help: participant.status })
      def create_request
        render json: participant.create_request(reason: params[:reason], share_metadata: params[:share_metadata], idempotency_key: request.headers["Idempotency-Key"]), status: :created
      end
      def cancel_request
        render json: participant.cancel_request(id: params[:id], expected_lock_version: params[:expected_lock_version])
      end
      def reopen_request
        render json: participant.reopen_request(id: params[:id], expected_lock_version: params[:expected_lock_version])
      end
      def restart_status = render(json: { financial_restart: restart.status(review_id: params[:review_id].presence) })
      def restart_preview = render(json: { financial_restart: restart.preview }, status: :created)
      def restart_apply
        render json: { financial_restart: restart.apply(review_id: params.require(:review_id), confirmation: params[:confirmation],
          shared_household_acknowledged: params[:shared_household_acknowledged]) }
      end
      def restart_cancel = render(json: { financial_restart: restart.cancel(review_id: params.require(:review_id)) })
      private
      def participant = SetupHelp::Participant.new(current_household, user: current_user, cohort_membership: current_cohort_membership)
      def restart = SetupHelp::Restart.new(current_household, user: current_user, cohort_membership: current_cohort_membership, request_id: params[:request_id].presence)
    end
  end
end
