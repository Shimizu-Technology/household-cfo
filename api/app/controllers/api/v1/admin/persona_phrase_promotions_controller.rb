# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaPhrasePromotionsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!

        def create
          promotion = promoter.promote!(
            persona_id: params[:persona_id],
            proposal_id: params.dig(:phrase_promotion, :proposal_id),
            expected_draft_revision: params.dig(:phrase_promotion, :draft_revision)
          )
          render_result(promotion, :created)
        rescue Mia::PersonaPhrasePromoter::Error => error
          render_promotion_error(error)
        end

        def restore
          promotion = promoter.restore!(
            persona_id: params[:persona_id],
            promotion_id: params[:id],
            expected_draft_revision: params.dig(:phrase_promotion, :draft_revision)
          )
          render_result(promotion, :ok)
        rescue Mia::PersonaPhrasePromoter::Error => error
          render_promotion_error(error)
        end

        private

        def promoter
          @promoter ||= Mia::PersonaPhrasePromoter.new(actor: current_user, workspace: coach_workspace_for_policy)
        end

        def render_result(promotion, status)
          persona = promotion.coach_persona.reload
          studio_policy = Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
          phrase_policy = Mia::ApprovedPhrasePolicy.new(current_user, workspace: coach_workspace_for_policy)
          render json: {
            persona: Mia::PersonaStudioSerializer.new(persona, policy: studio_policy).detail,
            phrase_promotion: Mia::ApprovedPhraseSerializer.new(policy: phrase_policy).promotion(promotion)
          }, status: status
        end

        def render_promotion_error(error)
          status = error.code == "phrase_promotion_not_found" ? :not_found :
            error.code.in?(%w[persona_draft_conflict phrase_promotion_conflict]) ? :conflict : :unprocessable_entity
          render json: { error: error.message, errors: [ error.message ], code: error.code }, status: status
        end
      end
    end
  end
end
