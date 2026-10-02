# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaReleaseReadinessController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        def show
          persona = policy.visible_personas.find(params[:persona_id])
          render json: { readiness: Mia::PersonaRelease::Readiness.new(persona: persona).call }
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end
      end
    end
  end
end
