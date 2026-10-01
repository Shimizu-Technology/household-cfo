# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortExperienceConfigurationsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def show
          render_configuration
        end

        def update
          unless cohort.status.in?(%w[draft enrolling active])
            return render json: {
              error: "Completed and archived cohorts are read-only.",
              code: "experience_configuration_read_only"
            }, status: :unprocessable_entity
          end
          editable_configuration.with_lock do
            return render_conflict unless expected_draft_revision == editable_configuration.draft_revision

            editable_configuration.update!(
              draft_config: submitted_config,
              last_edited_by_user: current_user
            )
          end
          render_configuration
        rescue ActiveRecord::StaleObjectError
          render_conflict
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def preview
          digest = CohortExperience::Publisher.new(configuration: editable_configuration, actor: current_user).preview!(
            expected_draft_revision: action_params[:draft_revision]
          )
          render json: {
            preview: preview_payload(digest),
            experience_configuration: serializer.detail
          }
        rescue CohortExperience::Publisher::PublicationError => error
          render json: { error: error.message, code: "experience_preview_conflict" }, status: :conflict
        end

        def publish
          version = CohortExperience::Publisher.new(configuration: editable_configuration, actor: current_user).publish!(
            expected_preview_digest: action_params[:preview_digest],
            expected_draft_revision: action_params[:draft_revision],
            expected_current_version_id: action_params[:expected_published_version_id]
          )
          render json: {
            experience_configuration: serializer.detail,
            published_version: serializer.serialize_version(version, include_config: true)
          }
        rescue CohortExperience::Publisher::PublicationError => error
          status = error.message.start_with?("Preview this exact") ? :unprocessable_entity : :conflict
          code = status == :unprocessable_entity ? "experience_preview_required" : "experience_publish_conflict"
          render json: { error: error.message, code: code }, status: status
        end

        private

        def policy
          @policy ||= CohortExperience::Policy.new(current_user)
        end

        def cohort
          @cohort ||= policy.manageable_cohorts.find(params[:cohort_id])
        end

        def editable_configuration
          @editable_configuration ||= cohort.cohort_experience_configuration || cohort.create_cohort_experience_configuration!(
            draft_config: CohortExperience::Schema::DEFAULT_CONFIG,
            last_edited_by_user: current_user
          )
        rescue ActiveRecord::RecordNotUnique
          cohort.reload.cohort_experience_configuration
        end

        def serializer
          CohortExperience::Serializer.new(configuration: editable_configuration.reload)
        end

        def render_configuration
          render json: { experience_configuration: serializer.detail }
        end

        def expected_draft_revision
          Integer(params.dig(:experience_configuration, :draft_revision), exception: false)
        end

        def submitted_config
          raw = params.require(:experience_configuration).require(:draft_config)
          raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        end

        def action_params
          @action_params ||= params.fetch(:experience_configuration, ActionController::Parameters.new)
            .permit(:draft_revision, :preview_digest, :expected_published_version_id)
        end

        def preview_payload(digest)
          config = editable_configuration.reload.draft_config
          enabled = config.fetch("optional_modules")
          {
            digest: digest,
            draft_revision: editable_configuration.draft_revision,
            generated_at: editable_configuration.previewed_at,
            modules: CohortExperience::ModuleRegistry::MODULES.map do |item|
              item.merge(enabled: item.fetch(:core) || enabled.fetch(item.fetch(:id), false))
            end
          }
        end

        def render_conflict
          render json: {
            error: "This participant-tools draft changed in another session. Reload before saving.",
            code: "experience_draft_conflict"
          }, status: :conflict
        end

        def render_invalid(record)
          render json: {
            error: record.errors.full_messages.first,
            errors: record.errors.full_messages,
            code: "experience_configuration_invalid"
          }, status: :unprocessable_entity
        end

        def render_not_found
          render json: { error: "Cohort experience configuration not found.", code: "experience_configuration_not_found" }, status: :not_found
        end
      end
    end
  end
end
