# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaSetupSessionsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def create
          persona = editable_persona
          session = nil
          ApplicationRecord.transaction do
            authorization = authorize_locked!(persona)
            raise PersonaSessionError, "Archived personas are read-only." if authorization.persona.archived?

            session = CoachPersonaSetupSession.active.find_by(
              coach_persona: authorization.persona,
              created_by_user: authorization.actor
            )
            session ||= CoachPersonaSetupSession.create!(
              coach_persona: authorization.persona,
              coach_workspace: authorization.workspace,
              created_by_user: authorization.actor,
              base_draft_revision: authorization.persona.draft_revision,
              base_config_digest: Mia::PersonaSchema.digest(authorization.persona.draft_config),
              last_activity_at: Time.current
            )
          end
          render_session(session, status: :created)
        rescue ActiveRecord::RecordNotUnique
          retry_session = CoachPersonaSetupSession.active.find_by!(coach_persona: editable_persona, created_by_user: current_user)
          render_session(retry_session)
        rescue PersonaSessionError => error
          render_error(error.message, code: "persona_setup_inactive", status: :unprocessable_entity)
        end

        def show
          render_session(scoped_session)
        end

        def rebase
          session = scoped_session
          ApplicationRecord.transaction do
            authorization = authorize_locked!(session.coach_persona)
            session.lock!
            raise PersonaSessionConflict unless session.status == "active"

            mark_open_work_stale!(session, authorization.actor)
            session.update!(
              base_draft_revision: authorization.persona.draft_revision,
              base_config_digest: Mia::PersonaSchema.digest(authorization.persona.draft_config),
              last_activity_at: Time.current
            )
          end
          render_session(session.reload)
        rescue PersonaSessionConflict
          render_error("This setup chat is no longer active.", code: "persona_setup_inactive", status: :conflict)
        end

        def destroy
          session = scoped_session
          ApplicationRecord.transaction do
            authorization = authorize_locked!(session.coach_persona)
            session.lock!
            mark_open_work_stale!(session, authorization.actor)
            session.update!(status: "abandoned", last_activity_at: Time.current)
          end
          render_session(session.reload)
        end

        private

        PersonaSessionError = Class.new(StandardError)
        PersonaSessionConflict = Class.new(StandardError)

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def editable_persona
          @editable_persona ||= policy.editable_personas.find(params[:persona_id])
        end

        def scoped_session
          CoachPersonaSetupSession.find_by!(
            id: params[:id],
            coach_persona_id: editable_persona.id,
            coach_workspace_id: current_coach_workspace.id,
            created_by_user_id: current_user.id
          )
        end

        def authorize_locked!(persona)
          Mia::PersonaSetup::Authorization.lock_editor!(
            actor_id: current_user.id,
            workspace_id: current_coach_workspace.id,
            persona_id: persona.id
          ) || raise(ActiveRecord::RecordNotFound)
        end

        def mark_open_work_stale!(session, actor)
          session.turns.where(status: "processing").order(:id).lock.each do |turn|
            turn.update!(status: "stale", assistant_message: "This response was stopped because the setup chat changed.")
          end
          session.proposals.where(status: "pending").order(:id).lock.each do |proposal|
            proposal.resolve!(status: "stale", actor:)
          end
        end

        def render_session(session, status: :ok)
          render json: { session: Mia::PersonaSetup::Serializer.new(session.reload).call }, status:
        end

        def not_found
          render_error("Persona setup session not found.", code: "persona_setup_not_found", status: :not_found)
        end

        def render_error(message, code:, status:)
          render json: { error: message, code: }, status:
        end
      end
    end
  end
end
