# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Opens or pauses the savings challenge for a cohort. Platform administrators
      # only: program owners and coaches can read the status on the cohort payload
      # but cannot change it. Every change is recorded in CohortChallengeAccessEvent.
      class CohortChallengeAccessesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_platform_admin!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from ActionController::ParameterMissing, SavingsChallenge::LaunchControl::Invalid, with: :render_invalid
        rescue_from SavingsChallenge::LaunchControl::NotAuthorized, with: :render_not_authorized
        rescue_from SavingsChallenge::LaunchControl::Refused, with: :render_refused
        rescue_from SavingsChallenge::LaunchControl::Conflict, with: :render_conflict

        def open
          result = control.open!(reason: input[:reason], request_key: request.headers["Idempotency-Key"], expected_state: input[:expected_state])
          render_result(result)
        end

        def pause
          result = control.pause!(reason: input[:reason], request_key: request.headers["Idempotency-Key"])
          render_result(result)
        end

        private

        def require_platform_admin!
          render_forbidden("Only a platform administrator can open or pause the savings challenge.") unless current_user.admin?
        end

        def cohort
          @cohort ||= Cohort.find(params[:cohort_id])
        end

        def control
          @control ||= SavingsChallenge::LaunchControl.new(cohort: cohort, actor: current_user)
        end

        def input
          params.require(:challenge_access).permit(:reason, :expected_state)
        end

        def render_result(result)
          render json: { savings_challenge: control.status, replayed: result.replayed }, status: result.replayed ? :ok : :created
        end

        def render_not_found
          render json: { error: "Cohort not found.", code: "challenge_access_not_found" }, status: :not_found
        end

        def render_invalid(error)
          render json: { error: error.message, code: "challenge_access_invalid" }, status: :unprocessable_entity
        end

        def render_not_authorized(error)
          render json: { error: error.message, code: "challenge_access_forbidden" }, status: :forbidden
        end

        def render_refused(error)
          render json: { error: error.message, code: "challenge_access_refused", savings_challenge: control.status }, status: :unprocessable_entity
        end

        def render_conflict(error)
          render json: { error: error.message, code: "challenge_access_conflict", savings_challenge: control.status }, status: :conflict
        end
      end
    end
  end
end
