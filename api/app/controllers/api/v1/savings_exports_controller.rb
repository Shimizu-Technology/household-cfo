module Api
  module V1
    class SavingsExportsController < BaseController
      wrap_parameters false
      before_action :authenticate_user!
      rescue_from ArgumentError do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { errors: [ "Private challenge export is unavailable" ] }, status: :not_found
      end
      rescue_from SavingsChallenge::AccessPolicy::Unavailable do |error|
        render json: { errors: [ error.message ] }, status: :forbidden
      end
      def show
        response.set_header("Cache-Control", "private, no-store")
        raise ArgumentError, "Choose whether optional feelings belong in your export" unless (params.to_unsafe_h.keys - %w[controller action include_reflections]).empty? && params[:include_reflections].to_s.in?(%w[true false])
        result = ApplicationRecord.transaction do
          current_household.lock!
          membership = current_cohort_membership || raise(SavingsChallenge::AccessPolicy::Unavailable, "Select your available challenge")
          enrollment = SavingsEnrollment.find_by!(household: current_household, user: current_user, cohort_id: membership.cohort_id)
          SavingsChallenge::Daily::ReadPolicy.call!(enrollment, user: current_user)
          SavingsChallenge::PersonalExport.new(enrollment, include_reflections: params[:include_reflections] == "true").call
        end
        render json: result
      end
    end
  end
end
