# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaEvaluationApprovalsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!

        def create
          persona = policy.publishable_personas.find(params[:persona_id])
          run = CoachPersonaEvaluationRun.joins(:release_candidate)
            .where(coach_persona_release_candidates: { coach_persona_id: persona.id }).find(params[:evaluation_run_id])
          approval = Mia::PersonaRelease::RunApprover.new(run: run, actor: current_user).call!(
            decision: approval_params[:decision],
            expected_run_digest: approval_params[:run_digest]
          )
          render json: { approval: Mia::PersonaRelease::Serializer.approval(approval) }, status: :created
        rescue Mia::PersonaRelease::RunApprover::Error => error
          render json: { error: error.message, code: "persona_evaluation_approval_invalid" }, status: :unprocessable_entity
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def approval_params
          params.require(:approval).permit(:decision, :run_digest)
        end
      end
    end
  end
end
