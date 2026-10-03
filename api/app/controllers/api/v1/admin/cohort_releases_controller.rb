# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortReleasesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from CoachOperations::Runner::NotAuthorized, CohortReleases::Sealer::NotAuthorized,
          with: :render_forbidden_operation
        rescue_from CoachOperations::Runner::IdempotencyConflict, CohortReleases::Sealer::RequestConflict,
          CohortReleases::Sealer::Stale, CohortReleases::Sealer::AlreadyRecorded,
          with: :render_conflict
        rescue_from CohortReleases::Sealer::ReadOnly, with: :render_read_only
        rescue_from CoachOperations::Runner::InvalidRequest, CoachOperations::Base::InvalidInput,
          ActiveRecord::RecordInvalid, ActionController::ParameterMissing, ArgumentError, with: :render_invalid
        rescue_from CohortReleases::Sealer::Incomplete, with: :render_incomplete

        def index
          render json: { cohort_release_studio: studio_payload }
        end

        def create
          result = run_operation(
            operation_key: CoachOperations::CohortReleaseSeal::KEY,
            input: seal_params
          )
          render_result(result)
        end

        def restore
          source = cohort.cohort_releases.find(params[:id])
          result = run_operation(
            operation_key: CoachOperations::CohortReleaseRestore::KEY,
            input: restore_params.merge(source_release_id: source.id)
          )
          render_result(result)
        end

        private

        def cohort
          @cohort ||= cohort_scope.find(params[:cohort_id])
        end

        def cohort_scope
          workspace = coach_workspace_for_policy
          workspace ? workspace.cohorts : Cohort.all
        end

        def studio_payload
          CohortReleases::StudioSerializer.new(cohort: cohort, actor: current_user).call
        end

        def run_operation(operation_key:, input:)
          operation = CoachOperations::Registry::OPERATIONS.fetch(operation_key)
          CoachOperations::Runner.new(cohort: cohort, actor: current_user).call!(
            operation_key: operation_key,
            operation_version: operation::VERSION,
            input: input,
            request_key: request.headers["Idempotency-Key"]
          )
        end

        def seal_params
          params.require(:release).permit(
            :expected_bundle_digest,
            :expected_assignment_id,
            :expected_persona_version_id,
            :expected_experience_version_id,
            :expected_brand_version_id,
            :expected_latest_release_id,
            :expected_tool_registry_digest,
            :expected_tool_registry_version
          ).to_h
        end

        def restore_params
          params.require(:release).permit(
            :expected_latest_release_id,
            :source_bundle_digest,
            :source_persona_version_id,
            :source_experience_version_id,
            :source_brand_version_id
          ).to_h
        end

        def render_result(result)
          studio, serialized_release = CohortReleases::StudioSerializer
            .new(cohort: cohort, actor: current_user)
            .call_with_release(result.release)
          render json: {
            release: serialized_release,
            operation_execution: execution_payload(result.execution),
            replayed: result.replayed,
            cohort_release_studio: studio
          }, status: result.replayed ? :ok : :created
        end

        def execution_payload(execution)
          {
            id: execution.id,
            operation_key: execution.operation_key,
            operation_version: execution.operation_version,
            request_key: execution.request_key,
            request_fingerprint: execution.request_fingerprint,
            cohort_release_id: execution.cohort_release_id,
            actor_user_id: execution.actor_user_id,
            actor_role_snapshot: execution.actor_role_snapshot,
            completed_at: execution.completed_at
          }
        end

        def render_not_found
          render json: { error: "Cohort release not found.", code: "cohort_release_not_found" }, status: :not_found
        end

        def render_forbidden_operation(error)
          render json: { error: error.message, code: "cohort_release_forbidden" }, status: :forbidden
        end

        def render_conflict(error)
          code = error.is_a?(CohortReleases::Sealer::AlreadyRecorded) ? "cohort_release_noop" : "cohort_release_conflict"
          render json: { error: error.message, code: code }, status: :conflict
        end

        def render_incomplete(error)
          render json: {
            error: error.message,
            errors: error.blockers,
            code: "cohort_release_incomplete"
          }, status: :unprocessable_entity
        end

        def render_read_only(error)
          render json: { error: error.message, code: "cohort_release_read_only" }, status: :unprocessable_entity
        end

        def render_invalid(error)
          messages = error.respond_to?(:record) ? error.record.errors.full_messages : [ error.message ]
          render json: {
            error: messages.first,
            errors: messages,
            code: "cohort_release_invalid"
          }, status: :unprocessable_entity
        end
      end
    end
  end
end
