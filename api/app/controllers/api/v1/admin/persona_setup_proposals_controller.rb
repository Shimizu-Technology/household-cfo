# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaSetupProposalsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def apply
          proposal = scoped_proposal
          persona = Mia::PersonaSetup::ProposalApplier.new(
            proposal:,
            actor: current_user,
            workspace: current_coach_workspace
          ).apply!(idempotency_key: request.headers["Idempotency-Key"])
          render json: {
            persona: Mia::PersonaStudioSerializer.new(persona, policy: policy).detail,
            session: Mia::PersonaSetup::Serializer.new(proposal.session.reload).call
          }
        rescue Mia::PersonaSetup::ProposalApplier::Error => error
          render json: { error: error.message, code: error.code }, status: error.status
        end

        def reject
          proposal = scoped_proposal
          Mia::PersonaSetup::ProposalApplier.new(
            proposal:,
            actor: current_user,
            workspace: current_coach_workspace
          ).reject!(idempotency_key: request.headers["Idempotency-Key"])
          render json: { session: Mia::PersonaSetup::Serializer.new(proposal.session.reload).call }
        rescue Mia::PersonaSetup::ProposalApplier::Error => error
          render json: { error: error.message, code: error.code }, status: error.status
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def scoped_proposal
          persona = policy.editable_personas.find(params[:persona_id])
          session = CoachPersonaSetupSession.find_by!(
            id: params[:setup_session_id],
            coach_persona_id: persona.id,
            coach_workspace_id: current_coach_workspace.id,
            created_by_user_id: current_user.id
          )
          session.proposals.find(params[:id])
        end

        def not_found
          render json: { error: "Persona setup proposal not found.", code: "persona_setup_not_found" }, status: :not_found
        end
      end
    end
  end
end
