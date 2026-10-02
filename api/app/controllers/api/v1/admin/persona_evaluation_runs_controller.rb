# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaEvaluationRunsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!, only: :create

        def index
          persona = policy.visible_personas.find(params[:persona_id])
          runs = CoachPersonaEvaluationRun.joins(:release_candidate)
            .where(coach_persona_release_candidates: { coach_persona_id: persona.id })
            .includes(:release_candidate, :requested_by_user, approval: :reviewed_by_user).order(created_at: :desc).limit(50)
          render json: { evaluation_runs: runs.map { |run| Mia::PersonaRelease::Serializer.run(run) } }
        end

        def show
          persona = policy.visible_personas.find(params[:persona_id])
          run = runs_for(persona).includes(:release_candidate, :requested_by_user, :approval, results: :evaluation_case).find(params[:id])
          render json: { evaluation_run: Mia::PersonaRelease::Serializer.run(run, include_results: true) }
        end

        def create
          persona = policy.editable_personas.find(params[:persona_id])
          result = Mia::PersonaRelease::Runner.new(persona: persona, actor: current_user)
            .enqueue!(request_key: run_params[:request_id])
          render json: {
            evaluation_run: Mia::PersonaRelease::Serializer.run(result.run, include_results: true),
            reconciliation: { request_id: result.run.request_key, replayed: result.replayed, enqueued: result.enqueued }
          }, status: :accepted
        rescue Mia::PersonaRelease::Runner::Error => error
          render json: { error: error.message, code: "persona_evaluation_failed" }, status: :unprocessable_entity
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def runs_for(persona)
          CoachPersonaEvaluationRun.joins(:release_candidate)
            .where(coach_persona_release_candidates: { coach_persona_id: persona.id })
        end

        def run_params
          params.require(:evaluation_run).permit(:request_id)
        end
      end
    end
  end
end
