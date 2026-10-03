# frozen_string_literal: true

module Api
  module V1
    module Admin
      class WorkspaceBrandVersionsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def show
          authorize!(:view)
          render json: {
            brand_configuration: serializer.detail,
            version: serializer.serialize_version(version, include_config: true, include_source: true)
          }
        end

        def rollback
          authorize!(:publish)
          restored = Branding::Rollback.new(
            configuration: configuration,
            target_version: version,
            actor: current_user
          ).call(
            expected_current_version_id: rollback_params[:expected_published_version_id],
            expected_draft_revision: rollback_params[:draft_revision],
            idempotency_key: request_idempotency_key
          )
          render json: {
            brand_configuration: serializer.detail,
            published_version: serializer.serialize_version(restored, include_config: true, include_source: true)
          }
        rescue Branding::Rollback::RollbackError => error
          render json: { error: error.message, code: "brand_rollback_conflict" }, status: :conflict
        end

        private

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
          @configuration ||= workspace.workspace_brand_configuration || raise(ActiveRecord::RecordNotFound)
        end

        def version
          @version ||= configuration.versions.find(params[:id])
        end

        def serializer
          Branding::Serializer.new(configuration: configuration.reload, actor: current_user)
        end

        def rollback_params
          params.require(:brand_configuration).permit(:expected_published_version_id, :draft_revision)
        end

        def render_not_found
          render json: { error: "Brand version not found.", code: "brand_version_not_found" }, status: :not_found
        end
      end
    end
  end
end
