# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortReleaseLaunchesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from CohortReleases::Authorization::NotAuthorized, with: :render_not_authorized
        rescue_from CohortReleases::InitialLauncher::Conflict, with: :render_conflict
        rescue_from CohortReleases::InitialLauncher::Incomplete, with: :render_incomplete
        rescue_from CohortReleases::InitialLauncher::Invalid, ActionController::ParameterMissing, with: :render_invalid

        def show
          render json: { launch: launcher.preview }
        end

        def create
          input = params.require(:launch).permit(:release_id, :preview_digest)
          result = launcher.call!(release_id: input[:release_id], preview_digest: input[:preview_digest],
            request_key: request.headers["Idempotency-Key"])
          render json: {
            launch: launcher.preview, replayed: result.replayed,
            activation: {
              id: result.event.id, release_id: result.event.to_cohort_release_id,
              event_type: result.event.event_type, actor_role: result.event.actor_role_snapshot,
              occurred_at: result.event.occurred_at
            }
          }, status: result.replayed ? :ok : :created
        end

        private

        def launcher
          @launcher ||= CohortReleases::InitialLauncher.new(cohort: cohort, actor: current_user)
        end

        def cohort
          @cohort ||= begin
            workspace = coach_workspace_for_policy
            (workspace ? workspace.cohorts : Cohort.all).find(params[:cohort_id])
          end
        end

        def render_not_found
          render json: { error: "Cohort launch not found.", code: "cohort_launch_not_found" }, status: :not_found
        end

        def render_not_authorized(_error)
          render json: { error: "Only a workspace owner or reviewer can launch a cohort.", code: "cohort_launch_forbidden" }, status: :forbidden
        end

        def render_conflict(error)
          render json: { error: error.message, code: "cohort_launch_conflict" }, status: :conflict
        end

        def render_incomplete(error)
          render json: { error: error.message, errors: error.blockers, code: "cohort_launch_incomplete" }, status: :unprocessable_entity
        end

        def render_invalid(error)
          render json: { error: error.message, code: "cohort_launch_invalid" }, status: :unprocessable_entity
        end
      end
    end
  end
end
