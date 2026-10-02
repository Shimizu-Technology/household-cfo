# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaAudienceAttestationsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!

        def create
          persona = policy.publishable_personas.find(params[:persona_id])
          attestation = Mia::PersonaRelease::AudienceAttester.new(persona: persona, actor: current_user).call!(
            candidate_digest: attestation_params[:candidate_digest],
            artifact_id: attestation_params[:artifact_id],
            artifact_fingerprint: attestation_params[:artifact_fingerprint],
            decision: attestation_params[:decision]
          )
          render json: { audience_attestation: Mia::PersonaRelease::Serializer.audience_attestation(attestation) }, status: :created
        rescue Mia::PersonaRelease::AudienceAttester::Error => error
          render json: { error: error.message, code: "persona_audience_attestation_invalid" }, status: :unprocessable_entity
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def attestation_params
          params.require(:audience_attestation).permit(
            :candidate_digest, :artifact_id, :artifact_fingerprint, :decision
          )
        end
      end
    end
  end
end
