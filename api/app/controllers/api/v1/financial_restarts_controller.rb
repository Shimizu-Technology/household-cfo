module Api
  module V1
    class FinancialRestartsController < BaseController
      before_action :authenticate_user!
      rescue_from HouseholdFinance::FinancialRestart::Flow::OwnerRequired do |error|
        render json: { errors: [ error.message ], code: "financial_restart_owner_required" }, status: :forbidden
      end
      rescue_from HouseholdFinance::FinancialRestart::Flow::StaleReview do |error|
        render json: { errors: [ error.message ], code: "financial_restart_review_stale" }, status: :conflict
      end
      rescue_from HouseholdFinance::FinancialRestart::Flow::Error do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Financial restart review not found for this account and program." ] }, status: :not_found
      end

      def status
        render json: { financial_restart: flow.status(review_id: params[:review_id].presence) }
      end

      def preview
        render json: { financial_restart: flow.preview }, status: :created
      end

      def apply
        render json: { financial_restart: flow.apply(review_id: params.require(:review_id),
          confirmation: params[:confirmation], shared_household_acknowledged: params[:shared_household_acknowledged]) }
      end

      def cancel
        render json: { financial_restart: flow.cancel(review_id: params.require(:review_id)) }
      end

      private
      def flow = HouseholdFinance::FinancialRestart::Flow.new(current_household, user: current_user, cohort_membership: current_cohort_membership)
    end
  end
end
