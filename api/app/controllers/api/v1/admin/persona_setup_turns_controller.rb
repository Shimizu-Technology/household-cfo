# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaSetupTurnsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def create
          session = scoped_session
          result = Mia::PersonaSetup::TurnRunner.new(
            session:,
            actor: current_user,
            workspace: current_coach_workspace,
            resolver: proposal_resolver
          ).call(
            user_message: params.dig(:turn, :message),
            idempotency_key: request.headers["Idempotency-Key"]
          )
          render json: { session: Mia::PersonaSetup::Serializer.new(result.session.reload).call }, status: result.replayed ? :ok : :created
        rescue Mia::PersonaSetup::TurnRunner::Error => error
          payload = { error: error.message, code: error.code }
          payload[:session] = Mia::PersonaSetup::Serializer.new(error.result.session.reload).call if error.result&.session
          render json: payload, status: error.status
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def scoped_session
          persona = policy.editable_personas.find(params[:persona_id])
          CoachPersonaSetupSession.find_by!(
            id: params[:setup_session_id],
            coach_persona_id: persona.id,
            coach_workspace_id: current_coach_workspace.id,
            created_by_user_id: current_user.id
          )
        end

        def proposal_resolver
          Mia::PersonaSetup::ProposalResolver.new
        end

        def not_found
          render json: { error: "Persona setup session not found.", code: "persona_setup_not_found" }, status: :not_found
        end
      end
    end
  end
end
