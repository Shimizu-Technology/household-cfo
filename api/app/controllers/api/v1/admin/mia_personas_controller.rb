# frozen_string_literal: true

module Api
  module V1
    module Admin
      class MiaPersonasController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def index
          personas = policy.visible_personas.includes(:created_by_user, current_published_version: :published_by_user).order(updated_at: :desc)
          render json: { personas: personas.map { |persona| serializer(persona).summary } }
        end

        def show
          render json: { persona: serializer(visible_persona).detail }
        end

        def create
          attributes = create_persona_params
          draft = attributes[:draft_config].presence || default_draft(attributes[:name])
          persona = CoachPersona.create!(
            name: attributes[:name].presence || draft.to_h.dig("identity", "assistant_name"),
            description: attributes[:description],
            draft_config: draft,
            created_by_user: current_user
          )
          render json: { persona: serializer(persona).detail }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_validation_error(error.record, code: "persona_invalid")
        end

        def update
          persona = editable_persona
          return render_api_error("Archived personas are read-only. Restore this persona before editing it.", code: "persona_archived", status: :unprocessable_entity) if persona.archived?
          if params.require(:persona).key?(:name)
            return render_api_error(
              "Update identity.assistant_name in the persona draft to rename this assistant.",
              code: "persona_name_is_draft_identity",
              status: :unprocessable_entity
            )
          end
          return render_revision_conflict unless expected_draft_revision == persona.draft_revision

          persona.update!(update_persona_params)
          render json: { persona: serializer(persona.reload).detail }
        rescue ActiveRecord::RecordInvalid => error
          render_validation_error(error.record, code: "persona_invalid")
        end

        def destroy
          persona = editable_persona
          assigned = persona.with_lock do
            next true if persona.cohort_persona_assignments.exists?

            persona.archive!
            false
          end

          if assigned
            return render_api_error(
              "Remove every cohort assignment before archiving this persona.",
              code: "persona_archive_assigned",
              status: :unprocessable_entity
            )
          end

          render json: { persona: serializer(persona.reload).detail }
        rescue ActiveRecord::RecordInvalid => error
          render_validation_error(error.record, code: "persona_archive_invalid")
        end

        def restore
          persona = editable_persona
          persona.restore!
          render json: { persona: serializer(persona.reload).detail }
        rescue ActiveRecord::RecordInvalid => error
          render_validation_error(error.record, code: "persona_restore_invalid")
        end

        def preview
          persona = editable_persona
          result = Mia::PersonaPublisher.new(persona: persona, actor: current_user).preview!(
            expected_draft_revision: preview_params[:draft_revision]
          )
          render json: {
            preview: {
              persona_id: persona.id,
              draft_revision: persona.draft_revision,
              digest: result.fetch(:digest),
              rendered_instructions: result.fetch(:prompt),
              sample_prompt: preview_params[:sample_prompt].to_s.squish.presence,
              sample_reply: sample_reply(persona),
              warnings: [],
              guardrails_applied: true,
              generated_at: persona.reload.previewed_at
            },
            persona: serializer(persona).detail
          }
        rescue Mia::PersonaPublisher::PublicationError => error
          render_studio_conflict(error.message, code: "persona_preview_conflict")
        end

        def publish
          persona = editable_persona
          version = Mia::PersonaPublisher.new(persona: persona, actor: current_user).publish!(
            expected_preview_digest: publish_params[:preview_digest],
            expected_draft_revision: publish_params[:draft_revision],
            expected_current_version_id: publish_params[:expected_published_version_id]
          )
          render json: {
            persona: serializer(persona.reload).detail,
            published_version: serializer(persona).serialize_version(version, include_config: true)
          }
        rescue Mia::PersonaPublisher::PublicationError => error
          render_publication_error(error)
        end

        def assignable_cohorts
          cohorts = policy.manageable_cohorts.includes(cohort_persona_assignment: [ :coach_persona, :coach_persona_version, :assigned_by_user ]).order(:name)
          render json: {
            cohorts: cohorts.map { |cohort| serialize_assignable_cohort(cohort) }
          }
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user)
        end

        def serializer(persona)
          Mia::PersonaStudioSerializer.new(persona, policy: policy)
        end

        def visible_persona
          @visible_persona ||= policy.visible_personas.find(params[:id])
        end

        def editable_persona
          @editable_persona ||= policy.editable_personas.find(params[:id])
        end

        def create_persona_params
          params.require(:persona).permit(:name, :description, draft_config: {}).to_h.deep_symbolize_keys
        end

        def update_persona_params
          params.require(:persona).permit(:description, draft_config: {}).to_h.deep_symbolize_keys
        end

        def preview_params
          @preview_params ||= params.fetch(:preview, ActionController::Parameters.new).permit(:draft_revision, :sample_prompt)
        end

        def publish_params
          @publish_params ||= params.require(:publish).permit(:draft_revision, :preview_digest, :expected_published_version_id)
        end

        def expected_draft_revision
          Integer(params.dig(:persona, :draft_revision), exception: false)
        end

        def default_draft(requested_name)
          name = requested_name.to_s.squish.presence || "Coach assistant"
          Mia::PersonaSchema.default_configuration(
            assistant_name: name,
            human_coach_name: current_user.full_name.presence || current_user.email,
            human_coach_title: "Financial coach"
          )
        end

        def sample_reply(persona)
          example = persona.draft_config.dig("curriculum", "examples")&.first
          return example.fetch("assistant") if example&.fetch("assistant", nil).present?

          assistant_name = persona.draft_config.dig("identity", "assistant_name")
          "I’m #{assistant_name}, your coach’s digital assistant. I’ll answer from verified household facts, explain the choice plainly, and give you one practical next move. Nothing changes until you review and approve it."
        end

        def serialize_assignable_cohort(cohort)
          mutable = cohort.status.in?(%w[draft enrolling active])
          assignment = cohort.cohort_persona_assignment
          {
            id: cohort.id,
            name: cohort.name,
            status: cohort.status,
            assignable: mutable,
            blocked_reason: mutable ? nil : "Completed and archived cohorts are read-only.",
            persona_assignment: assignment && Mia::PersonaStudioSerializer.new(assignment.coach_persona, policy: policy).serialize_assignment(assignment)
          }
        end

        def render_revision_conflict
          render_studio_conflict(
            "This persona changed in another session. Reload the current draft before saving.",
            code: "persona_draft_conflict"
          )
        end

        def render_publication_error(error)
          if error.message == "Preview this exact draft before publishing"
            render_api_error(error.message, code: "persona_preview_required", status: :unprocessable_entity)
          else
            render_studio_conflict(error.message, code: "persona_publish_conflict")
          end
        end

        def render_studio_conflict(message, code:)
          render json: { error: message, code: code }, status: :conflict
        end

        def render_validation_error(record, code:)
          messages = record.errors.full_messages
          render json: { error: messages.first, errors: messages, code: code }, status: :unprocessable_entity
        end

        def render_api_error(message, code:, status:)
          render json: { error: message, errors: [ message ], code: code }, status: status
        end

        def render_not_found(error)
          render_api_error(error.message, code: "persona_not_found", status: :not_found)
        end
      end
    end
  end
end
