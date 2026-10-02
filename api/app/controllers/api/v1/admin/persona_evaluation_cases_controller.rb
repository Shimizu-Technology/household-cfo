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
          persisted_system = records.select { |record| record.case_kind == "system" }.index_by(&:system_key)
          required = Mia::PersonaRelease::SystemCases.catalog.map do |definition|
            Mia::PersonaRelease::Serializer.system_case_definition(
              definition,
              record: persisted_system[definition.fetch(:system_key)]
            )
          end
          custom = records.select { |record| record.case_kind == "custom" }
            .map { |record| Mia::PersonaRelease::Serializer.evaluation_case(record) }
          render json: { evaluation_cases: required + custom }
        end

        def create
          persona = policy.editable_personas.find(params[:persona_id])
          attributes = case_params
          request_key = Mia::PersonaRelease::RequestIdentity.normalize!(attributes[:request_id])
          request_fingerprint = Mia::PersonaRelease::RequestIdentity.fingerprint(
            schema: "persona_evaluation_case_request_v1",
            request_key: request_key,
            persona_id: persona.id,
            actor_id: current_user.id,
            name: attributes[:name],
            prompt: attributes[:prompt],
            assertions: attributes[:assertions]
          )
          replayed = false
          record = persona.with_lock do
            if persona.archived?
              persona.errors.add(:base, "Archived personas are read-only")
              raise ActiveRecord::RecordInvalid.new(persona)
            end
            existing = CoachPersonaEvaluationCase.find_by(request_key: request_key)
            if existing
              replayed = true
              unless same_request?(existing, persona, request_fingerprint)
                raise ArgumentError, "request_id was already used for a different evaluation case"
              end
              next existing
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
              active: true,
              request_key: request_key,
              request_fingerprint: request_fingerprint
            )
            evaluation_case.case_digest = CoachPersonaEvaluationCase.digest_for(evaluation_case)
            evaluation_case.save!
            evaluation_case
          end
          render_record(record, request_key, replayed: replayed)
        rescue ActiveRecord::RecordNotUnique
          record = CoachPersonaEvaluationCase.find_by!(request_key: request_key)
          unless same_request?(record, persona, request_fingerprint)
            return render json: {
              error: "request_id was already used for a different evaluation case",
              code: "persona_evaluation_case_invalid"
            }, status: :unprocessable_entity
          end

          render_record(record, request_key, replayed: true)
        rescue ActiveRecord::RecordInvalid => error
          render json: { error: error.record.errors.full_messages.first, code: "persona_evaluation_case_invalid" }, status: :unprocessable_entity
        rescue ArgumentError => error
          render json: { error: error.message, code: "persona_evaluation_case_invalid" }, status: :unprocessable_entity
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
          params.require(:evaluation_case).permit(:request_id, :name, :prompt, assertions: [ :type, :value, { values: [] } ])
        end

        def same_request?(record, persona, fingerprint)
          record.coach_persona_id == persona.id && record.created_by_user_id == current_user.id &&
            record.request_fingerprint == fingerprint
        end

        def render_record(record, request_key, replayed:)
          render json: {
            evaluation_case: Mia::PersonaRelease::Serializer.evaluation_case(record),
            reconciliation: { request_id: request_key, replayed: replayed }
          }, status: :created
        end
      end
    end
  end
end
