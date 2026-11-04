# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachLaunchesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!

        def create
          perform_launch { |publisher| { launch: publisher.call! } }
        end

        def resolve
          perform_launch(&:resolve!)
        end

        private

        def perform_launch
          unless params[:review].is_a?(ActionController::Parameters)
            return render json: { error: "Reopen Go live to review this update." }, status: :unprocessable_entity
          end
          policy = Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
          persona = policy.publishable_personas.find(params[:id])
          publisher = CoachLaunches::Publisher.new(persona:, actor: current_user,
            review: params.require(:review).to_unsafe_h, request_key: request.headers["Idempotency-Key"])
          result = yield publisher
          render json: result.merge(persona: Mia::PersonaStudioSerializer.new(persona.reload, policy:).detail)
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Ask a program owner to review and publish this update." }, status: :forbidden
        rescue CoachLaunches::Publisher::Conflict, Branding::Publisher::PublicationError,
          CohortExperience::Publisher::PublicationError, Mia::PersonaPublisher::PublicationError,
          Mia::PersonaRelease::AudienceAttester::Error, Mia::PersonaRelease::RunApprover::Error,
          CoachOperations::Runner::Error, CohortReleases::Sealer::Stale,
          CohortReleases::Sealer::Incomplete, CohortReleases::Sealer::ReadOnly,
          CohortRollouts::StateMachine::Error, CohortReleases::InitialLauncher::Conflict,
          CohortReleases::InitialLauncher::Incomplete, Mia::PersonaAssignmentCompatibility::Conflict,
          ActiveRecord::StatementInvalid, ActiveRecord::RecordInvalid, KeyError, ArgumentError, TypeError, ActionController::ParameterMissing => error
          Rails.logger.info("[CoachLaunch] rejected #{error.class.name}")
          render json: { error: "This update could not finish. Check this update before trying again." }, status: :conflict
        end
      end
    end
  end
end
