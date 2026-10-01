# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaContentPacksController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        def update
          persona_policy = Mia::PersonaStudioPolicy.new(current_user)
          persona = persona_policy.editable_personas.find(params[:persona_id])
          expected = Integer(params.dig(:content_packs, :draft_revision), exception: false)

          ids = Array(params.dig(:content_packs, :pack_version_ids)).map(&:to_i).select(&:positive?).uniq
          content_policy = Mia::ContentLibraryPolicy.new(current_user)
          retained_ids = persona.draft_content_pack_version_ids & ids
          newly_selected_ids = ids - retained_ids
          visible_versions = CoachContentPackVersion.where(
            coach_content_pack_id: content_policy.visible_packs.select(:id),
            id: retained_ids
          )
          selectable_versions = content_policy.visible_pack_versions.where(id: newly_selected_ids)
          versions = visible_versions.or(selectable_versions).includes(:coach_content_pack).index_by(&:id)
          return unavailable unless versions.length == ids.length

          persona.replace_draft_content_pack_versions!(
            ids.map { |id| versions.fetch(id) },
            actor: current_user,
            expected_draft_revision: expected
          )
          render json: { persona: Mia::PersonaStudioSerializer.new(persona.reload, policy: persona_policy).detail }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Persona not found.", code: "persona_not_found" }, status: :not_found
        rescue ArgumentError => error
          render json: { error: error.message, code: "persona_content_packs_invalid" }, status: :unprocessable_entity
        rescue CoachPersona::DraftConflict
          conflict
        end

        private

        def conflict
          render json: { error: "The persona draft changed; reload it before changing content packs.", code: "persona_draft_conflict" }, status: :conflict
        end

        def unavailable
          render json: { error: "One or more content pack versions are unavailable.", code: "persona_content_pack_unavailable" }, status: :unprocessable_entity
        end
      end
    end
  end
end
