# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaAssignmentsController < BaseController
        MUTABLE_COHORT_STATUSES = %w[draft enrolling active].freeze

        before_action :authenticate_user!
        before_action :require_staff!
        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

        def show
          cohort = manageable_cohort
          assignment = cohort.cohort_persona_assignment
          render json: { persona_assignment: assignment && serializer(assignment.coach_persona).serialize_assignment(assignment) }
        end

        def update
          cohort = manageable_cohort
          return render_read_only_cohort(cohort) unless cohort.status.in?(MUTABLE_COHORT_STATUSES)

          persona = policy.editable_personas.find(assignment_params[:persona_id])
          assignment = nil
          CohortPersonaAssignment.transaction do
            persona.lock!
            cohort.lock!
            raise PersonaUnavailable unless persona.published? && !persona.archived?

            participant_ids = Mia::PersonaAssignmentCompatibility.participant_ids_for(cohort: cohort)
            Mia::PersonaAssignmentCompatibility.lock_participants!(user_ids: participant_ids)
            current = cohort.cohort_persona_assignment
            validate_expected_assignment!(current)
            Mia::PersonaAssignmentCompatibility.ensure_cohort_can_use!(cohort: cohort, persona: persona)
            assignment = current || cohort.build_cohort_persona_assignment
            assignment.update!(
              coach_persona: persona,
              coach_persona_version: persona.current_published_version,
              assigned_by_user: current_user
            )
          end
          render json: { persona_assignment: serializer(persona).serialize_assignment(assignment.reload) }
        rescue Mia::PersonaAssignmentCompatibility::Conflict => error
          render json: { error: error.message, code: "persona_assignment_conflict", conflicts: error.conflicts }, status: :conflict
        rescue AssignmentConflict => error
          render json: { error: error.message, code: "persona_assignment_stale" }, status: :conflict
        rescue PersonaUnavailable
          render json: { errors: [ "Publish this persona before assigning it." ], code: "persona_assignment_unavailable" }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => error
          render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
        end

        def destroy
          cohort = manageable_cohort
          return render_read_only_cohort(cohort) unless cohort.status.in?(MUTABLE_COHORT_STATUSES)

          CohortPersonaAssignment.transaction do
            cohort.lock!
            current = cohort.cohort_persona_assignment
            validate_expected_assignment!(current)
            current&.destroy!
          end
          head :no_content
        rescue AssignmentConflict => error
          render json: { error: error.message, code: "persona_assignment_stale" }, status: :conflict
        end

        private

        class AssignmentConflict < StandardError; end
        class PersonaUnavailable < StandardError; end

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user)
        end

        def serializer(persona)
          Mia::PersonaStudioSerializer.new(persona, policy: policy)
        end

        def manageable_cohort
          @manageable_cohort ||= policy.manageable_cohorts.find(params[:cohort_id])
        end

        def assignment_params
          @assignment_params ||= params.require(:persona_assignment).permit(:persona_id, :expected_persona_id)
        end

        def validate_expected_assignment!(assignment)
          expected = normalized_id(assignment_params[:expected_persona_id])
          actual = assignment&.coach_persona_id
          return if expected == actual

          raise AssignmentConflict, "This cohort assignment changed in another session. Reload before saving."
        end

        def normalized_id(value)
          return nil if value.blank?

          Integer(value, exception: false) || :invalid
        end

        def render_read_only_cohort(cohort)
          render json: { errors: [ "#{cohort.status.titleize} cohorts are read-only." ] }, status: :unprocessable_entity
        end

        def render_not_found(error)
          render json: { errors: [ error.message ] }, status: :not_found
        end
      end
    end
  end
end
