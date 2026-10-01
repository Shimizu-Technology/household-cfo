# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortExperienceConfigurationsController < BaseController
        class InvalidConfigurationInput < StandardError; end

        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from InvalidConfigurationInput, with: :render_invalid_input

        def show
          render_configuration
        end

        def update
          next_config = submitted_config
          next_revision = expected_draft_revision
          cohort.with_lock do
            configuration = editable_configuration
            configuration.lock!
            return render_read_only unless cohort.status.in?(%w[draft enrolling active])
            return render_conflict unless next_revision == configuration.draft_revision

            configuration.update!(
              draft_config: next_config,
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
        rescue CohortExperience::Publisher::ReadOnlyError => error
          render json: { error: error.message, code: "experience_configuration_read_only" }, status: :unprocessable_entity
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
        rescue CohortExperience::Publisher::PreviewRequiredError => error
          render json: { error: error.message, code: "experience_preview_required" }, status: :unprocessable_entity
        rescue CohortExperience::Publisher::ReadOnlyError => error
          render json: { error: error.message, code: "experience_configuration_read_only" }, status: :unprocessable_entity
        rescue CohortExperience::Publisher::PublicationError => error
          render json: { error: error.message, code: "experience_publish_conflict" }, status: :conflict
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
          Integer(configuration_input[:draft_revision], exception: false)
        end

        def submitted_config
          raw = configuration_input[:draft_config]
          return raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
          return raw if raw.is_a?(Hash)

          raise InvalidConfigurationInput, "Participant-tools configuration must be an object."
        end

        def action_params
          @action_params ||= configuration_input.permit(:draft_revision, :preview_digest, :expected_published_version_id)
        end

        def configuration_input
          raw = params[:experience_configuration]
          return raw if raw.is_a?(ActionController::Parameters)
          return ActionController::Parameters.new(raw) if raw.is_a?(Hash)

          raise InvalidConfigurationInput, "Participant-tools configuration must be an object."
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

        def render_read_only
          render json: {
            error: "Completed and archived cohorts are read-only.",
            code: "experience_configuration_read_only"
          }, status: :unprocessable_entity
        end

        def render_invalid_input(error)
          render json: {
            error: error.message,
            errors: [ error.message ],
            code: "experience_configuration_invalid"
          }, status: :unprocessable_entity
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
