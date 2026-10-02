# frozen_string_literal: true

module Api
  module V1
    module Admin
      class MiaPersonaVersionsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def show
          persona = policy.visible_personas.find(params[:persona_id])
          version = persona.versions.find(params[:id])
          render json: {
            persona: serializer(persona).summary,
            version: serializer(persona).serialize_version(
              version,
              include_config: policy.can_view_private_configuration?(persona),
              include_source: true
            )
          }
        end

        def rollback
          persona = policy.editable_personas.find(params[:persona_id])
          version = persona.versions.find(params[:id])
          restore_event = Mia::PersonaRollback.new(persona: persona, target_version: version, actor: current_user).call(
            expected_current_version_id: rollback_params[:expected_published_version_id],
            expected_draft_revision: rollback_params[:draft_revision]
          )
          render json: {
            persona: serializer(persona.reload).detail,
            draft_restore: Mia::PersonaStudioSerializer.serialize_draft_restore_event(restore_event)
          }
        rescue Mia::PersonaRollback::RollbackError => error
          render json: { error: error.message, code: "persona_rollback_conflict" }, status: :conflict
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def serializer(persona)
          Mia::PersonaStudioSerializer.new(persona, policy: policy)
        end

        def rollback_params
          params.require(:rollback).permit(:expected_published_version_id, :draft_revision)
        end

        def render_not_found(error)
          Rails.logger.warn(
            "[MiaPersonaVersionsController] record not found error=#{error.class} message=#{error.message.inspect}"
          )
          render json: {
            error: "Persona version not found.",
            errors: [ "Persona version not found." ],
            code: "persona_version_not_found"
          }, status: :not_found
        end
      end
    end
  end
end
