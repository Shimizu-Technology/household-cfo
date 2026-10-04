# frozen_string_literal: true

module Api
  module V1
    module Admin
      class WorkspaceBrandConfigurationsController < BaseController
        class InvalidConfigurationInput < StandardError; end

        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from InvalidConfigurationInput, with: :render_invalid_input

        def show
          authorize!(:view)
          render_configuration
        end

        def update
          authorize!(:edit)
          next_config = submitted_config
          next_revision = expected_draft_revision
          CoachWorkspaces::MutationAuthority.new(workspace: workspace, actor: current_user, permissions: :edit).call do |actor|
            configuration.lock!
            return render_conflict unless next_revision == configuration.draft_revision

            configuration.update!(draft_config: next_config, last_edited_by_user: actor)
          end
          render_configuration
        rescue ActiveRecord::StaleObjectError
          render_conflict
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def preview
          authorize!(:preview)
          digest = Publisher.new(configuration: configuration, actor: current_user).preview!(
            expected_draft_revision: action_params[:draft_revision]
          )
          render json: {
            preview: {
              digest: digest,
              draft_revision: configuration.reload.draft_revision,
              generated_at: configuration.previewed_at,
              brand: configuration.draft_config
            },
            brand_configuration: serializer.detail
          }
        rescue Publisher::PublicationError => error
          render json: { error: error.message, code: "brand_preview_conflict" }, status: :conflict
        end

        def publish
          authorize!(:publish)
          version = Publisher.new(configuration: configuration, actor: current_user).publish!(
            expected_preview_digest: action_params[:preview_digest],
            expected_draft_revision: action_params[:draft_revision],
            expected_current_version_id: action_params[:expected_published_version_id],
            idempotency_key: request_idempotency_key
          )
          render json: {
            brand_configuration: serializer.detail,
            published_version: serializer.serialize_version(version, include_config: true)
          }
        rescue Publisher::PreviewRequiredError => error
          render json: { error: error.message, code: "brand_preview_required" }, status: :unprocessable_entity
        rescue Publisher::PublicationError => error
          render json: { error: error.message, code: "brand_publish_conflict" }, status: :conflict
        end

        private

        Publisher = Branding::Publisher

        def workspace
          @workspace ||= begin
            if current_user.admin? && request.headers["X-Coach-Workspace-Id"].blank?
              raise ActiveRecord::RecordNotFound
            end
            current_coach_workspace
          end
        end

        def policy
          @policy ||= Branding::Policy.new(current_user, workspace: workspace)
        end

        def authorize!(permission)
          raise ActiveRecord::RecordNotFound unless policy.public_send("#{permission}?")
        end

        def configuration
          @configuration ||= Branding::Provisioner.ensure_for!(workspace: workspace)
        end

        def serializer
          Branding::Serializer.new(configuration: configuration.reload, actor: current_user)
        end

        def render_configuration
          render json: { brand_configuration: serializer.detail }
        end

        def expected_draft_revision
          Integer(configuration_input[:draft_revision], exception: false)
        end

        def submitted_config
          raw = configuration_input[:draft_config]
          return raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
          return raw if raw.is_a?(Hash)

          raise InvalidConfigurationInput, "Brand configuration must be an object."
        end

        def action_params
          @action_params ||= configuration_input.permit(:draft_revision, :preview_digest, :expected_published_version_id)
        end

        def configuration_input
          raw = params[:brand_configuration]
          return raw if raw.is_a?(ActionController::Parameters)
          return ActionController::Parameters.new(raw) if raw.is_a?(Hash)

          raise InvalidConfigurationInput, "Brand configuration must be an object."
        end

        def render_conflict
          render json: {
            error: "This brand draft changed in another session. Reload before saving.",
            code: "brand_draft_conflict"
          }, status: :conflict
        end

        def render_invalid_input(error)
          render json: { error: error.message, errors: [ error.message ], code: "brand_configuration_invalid" },
            status: :unprocessable_entity
        end

        def render_invalid(record)
          render json: {
            error: record.errors.full_messages.first,
            errors: record.errors.full_messages,
            code: "brand_configuration_invalid"
          }, status: :unprocessable_entity
        end

        def render_not_found
          render json: { error: "Brand configuration not found.", code: "brand_configuration_not_found" }, status: :not_found
        end
      end
    end
  end
end
