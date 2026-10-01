# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortExperienceVersionsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def show
          render json: {
            experience_configuration: serializer.detail,
            version: serializer.serialize_version(version, include_config: true, include_source: true)
          }
        end

        def rollback
          restored = CohortExperience::Rollback.new(
            configuration: configuration,
            target_version: version,
            actor: current_user
          ).call(
            expected_current_version_id: rollback_params[:expected_published_version_id],
            expected_draft_revision: rollback_params[:draft_revision]
          )
          render json: {
            experience_configuration: serializer.detail,
            published_version: serializer.serialize_version(restored, include_config: true, include_source: true)
          }
        rescue CohortExperience::Rollback::RollbackError => error
          render json: { error: error.message, code: "experience_rollback_conflict" }, status: :conflict
        end

        private

        def policy
          @policy ||= CohortExperience::Policy.new(current_user)
        end

        def cohort
          @cohort ||= policy.manageable_cohorts.find(params[:cohort_id])
        end

        def configuration
          @configuration ||= cohort.cohort_experience_configuration || raise(ActiveRecord::RecordNotFound)
        end

        def version
          @version ||= configuration.versions.find(params[:id])
        end

        def serializer
          CohortExperience::Serializer.new(configuration: configuration.reload)
        end

        def rollback_params
          params.require(:experience_configuration).permit(:expected_published_version_id, :draft_revision)
        end

        def render_not_found
          render json: { error: "Cohort experience version not found.", code: "experience_version_not_found" }, status: :not_found
        end
      end
    end
  end
end
