# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaEvaluationCasesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!, only: %i[create destroy]

        def index
          persona = policy.visible_personas.find(params[:persona_id])
          records = persona.evaluation_cases.order(required: :desc, created_at: :asc)
          render json: { evaluation_cases: records.map { |record| Mia::PersonaRelease::Serializer.evaluation_case(record) } }
        end

        def create
          persona = policy.editable_personas.find(params[:persona_id])
          attributes = case_params
          record = persona.with_lock do
            if persona.archived?
              persona.errors.add(:base, "Archived personas are read-only")
              raise ActiveRecord::RecordInvalid.new(persona)
            end
            active_custom_limit = Mia::PersonaRelease::Runner::MAX_CASES - Mia::PersonaRelease::SystemCases::DEFINITIONS.length
            if persona.evaluation_cases.where(case_kind: "custom", active: true).count >= active_custom_limit
              persona.errors.add(:base, "Retire an existing custom evaluation case before adding another")
              raise ActiveRecord::RecordInvalid.new(persona)
            end

            evaluation_case = persona.evaluation_cases.new(
              coach_workspace: persona.coach_workspace,
              created_by_user: current_user,
              name: attributes[:name],
              prompt: attributes[:prompt],
              assertions: attributes[:assertions],
              case_kind: "custom",
              required: false,
              active: true
            )
            evaluation_case.case_digest = CoachPersonaEvaluationCase.digest_for(evaluation_case)
            evaluation_case.save!
            evaluation_case
          end
          render json: { evaluation_case: Mia::PersonaRelease::Serializer.evaluation_case(record) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render json: { error: error.record.errors.full_messages.first, code: "persona_evaluation_case_invalid" }, status: :unprocessable_entity
        end

        def destroy
          persona = policy.editable_personas.find(params[:persona_id])
          record = persona.with_lock do
            raise ArgumentError, "Archived personas are read-only" if persona.archived?

            evaluation_case = persona.evaluation_cases.find(params[:id])
            evaluation_case.retire!(actor: current_user)
          end
          render json: { evaluation_case: Mia::PersonaRelease::Serializer.evaluation_case(record.reload) }
        rescue ArgumentError => error
          render json: { error: error.message, code: "persona_evaluation_case_invalid" }, status: :unprocessable_entity
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def case_params
          params.require(:evaluation_case).permit(:name, :prompt, assertions: [ :type, :value, { values: [] } ])
        end
      end
    end
  end
end
