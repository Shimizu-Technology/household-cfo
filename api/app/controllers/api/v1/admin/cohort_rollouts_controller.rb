# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CohortRolloutsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!

        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from CoachOperations::Runner::NotAuthorized, CohortReleases::Authorization::NotAuthorized,
          with: :render_forbidden_operation
        rescue_from CoachOperations::Runner::IdempotencyConflict, CohortRollouts::StateMachine::Stale,
          CohortRollouts::StateMachine::InvalidTransition, ActiveRecord::RecordNotUnique,
          with: :render_conflict
        rescue_from CohortRollouts::StateMachine::ReadOnly, with: :render_read_only
        rescue_from CohortRollouts::StateMachine::Ineligible, with: :render_incomplete
        rescue_from CoachOperations::Runner::InvalidRequest, CoachOperations::Base::InvalidInput,
          ActiveRecord::RecordInvalid, ActionController::ParameterMissing, ArgumentError,
          with: :render_invalid

        def index
          render json: { cohort_rollout_studio: studio_payload }
        end

        def show
          studio, serialized_rollout = serializer.call_with_rollout(rollout)
          render json: { rollout: serialized_rollout, cohort_rollout_studio: studio }
        end

        def create
          render_result(run_operation("cohort.rollout.plan", plan_params))
        end

        def advance
          render_result(run_operation("cohort.rollout.advance", transition_params(:readiness_digest)))
        end

        def pause
          render_result(run_operation("cohort.rollout.pause", transition_params))
        end

        def resume
          render_result(run_operation("cohort.rollout.resume", transition_params))
        end

        def cancel
          render_result(run_operation("cohort.rollout.cancel", transition_params))
        end

        def rollback
          render_result(run_operation("cohort.rollout.rollback", transition_params(:rollback_release_id)))
        end

        private

        def cohort
          @cohort ||= cohort_scope.find(params[:cohort_id])
        end

        def rollout
          @rollout ||= cohort.cohort_rollouts.find(params[:id])
        end

        def cohort_scope
          workspace = coach_workspace_for_policy
          workspace ? workspace.cohorts : Cohort.all
        end

        def studio_payload
          serializer.call
        end

        def serializer
          @serializer ||= CohortRollouts::StudioSerializer.new(cohort: cohort, actor: current_user)
        end

        def run_operation(operation_key, input)
          operation_input = input
          operation_input = input.merge(rollout_id: rollout.id) unless operation_key == "cohort.rollout.plan"
          CoachOperations::Runner.new(cohort: cohort, actor: current_user).call!(
            operation_key: operation_key,
            operation_version: operation_version_for(operation_key),
            input: operation_input,
            request_key: request.headers["Idempotency-Key"]
          )
        end

        def operation_version_for(operation_key)
          return 2 if operation_key == "cohort.rollout.plan"

          rollout.baseline_cohort_release_id ? 2 : 1
        end

        def plan_params
          params.require(:rollout).permit(
            :target_release_id,
            :expected_latest_release_id,
            :expected_roster_digest,
            waves: [ :name, { user_ids: [] } ]
          ).to_h
        end

        def transition_params(*extra_keys)
          params.require(:rollout).permit(
            :expected_status,
            :expected_current_wave_position,
            :expected_latest_transition_id,
            *extra_keys
          ).to_h
        end

        def render_result(result)
          studio, serialized_rollout = serializer.call_with_rollout(result.rollout)
          render json: {
            rollout: serialized_rollout,
            transition: transition_payload(result.transition),
            operation_execution: execution_payload(result.execution),
            replayed: result.replayed,
            cohort_rollout_studio: studio
          }, status: result.replayed ? :ok : :created
        end

        def transition_payload(transition)
          {
            id: transition.id,
            event_type: transition.event_type,
            from_status: transition.from_status,
            to_status: transition.to_status,
            from_wave_position: transition.from_wave_position,
            to_wave_position: transition.to_wave_position,
            readiness_digest: transition.readiness_digest,
            rollback_release_id: transition.rollback_cohort_release_id,
            participant_runtime_changed: transition.participant_runtime_changed,
            occurred_at: transition.occurred_at
          }
        end

        def execution_payload(execution)
          {
            id: execution.id,
            operation_key: execution.operation_key,
            operation_version: execution.operation_version,
            request_key: execution.request_key,
            request_fingerprint: execution.request_fingerprint,
            cohort_rollout_transition_id: execution.cohort_rollout_transition_id,
            actor_user_id: execution.actor_user_id,
            actor_role_snapshot: execution.actor_role_snapshot,
            completed_at: execution.completed_at
          }
        end

        def render_not_found
          render json: { error: "Cohort rollout not found.", code: "cohort_rollout_not_found" }, status: :not_found
        end

        def render_forbidden_operation(_error)
          render json: {
            error: "Only a workspace owner or reviewer can manage rollout records.",
            code: "cohort_rollout_forbidden"
          }, status: :forbidden
        end

        def render_conflict(error)
          render json: { error: error.message, code: "cohort_rollout_conflict" }, status: :conflict
        end

        def render_incomplete(error)
          render json: {
            error: error.message,
            errors: error.blockers,
            code: "cohort_rollout_incomplete"
          }, status: :unprocessable_entity
        end

        def render_read_only(error)
          render json: { error: error.message, code: "cohort_rollout_read_only" }, status: :unprocessable_entity
        end

        def render_invalid(error)
          messages = error.respond_to?(:record) ? error.record.errors.full_messages : [ error.message ]
          render json: {
            error: messages.first,
            errors: messages,
            code: "cohort_rollout_invalid"
          }, status: :unprocessable_entity
        end
      end
    end
  end
end
