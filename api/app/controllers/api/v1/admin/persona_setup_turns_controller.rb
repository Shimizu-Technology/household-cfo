# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PersonaSetupTurnsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def create
          session = scoped_session
          result = Mia::PersonaSetup::TurnRunner.new(
            session:,
            actor: current_user,
            workspace: current_coach_workspace,
            resolver: proposal_resolver
          ).call(
            user_message: params.dig(:turn, :message),
            idempotency_key: request.headers["Idempotency-Key"]
          )
          render json: { session: Mia::PersonaSetup::Serializer.new(result.session.reload).call }, status: result.replayed ? :ok : :created
        rescue Mia::PersonaSetup::TurnRunner::Error => error
          payload = { error: error.message, code: error.code }
          payload[:session] = Mia::PersonaSetup::Serializer.new(error.result.session.reload).call if error.result&.session
          render json: payload, status: error.status
        end

        def transcript
          scoped_session
          file = params[:file]
          unless file.is_a?(ActionDispatch::Http::UploadedFile)
            return render json: { error: "Choose a TXT, DOCX, or PDF transcript." }, status: :unprocessable_entity
          end
          unless File.extname(file.original_filename).downcase.in?(%w[.txt .docx .pdf])
            return render json: { error: "Choose a TXT, DOCX, or PDF transcript." }, status: :unprocessable_entity
          end
          ContentSources::UploadValidator.validate_metadata!(filename: file.original_filename,
            content_type: file.content_type, byte_size: file.size, checksum_sha256: Digest::SHA256.file(file.path).hexdigest)
          parsed = ContentSources::Parser.new.call(path: file.path, filename: file.original_filename)
          text = parsed.segments.map(&:text).join("\n\n")
          if text.blank?
            return render json: { error: "This transcript has no readable text. Try a TXT file or paste its text." }, status: :unprocessable_entity
          end
          if text.length > 22_000
            return render json: { error: "This transcript is long. Choose an excerpt of up to 22,000 characters." }, status: :unprocessable_entity
          end
          render json: { text: text }
        rescue ContentSources::Error
          render json: { error: "This transcript could not be read safely. Try a TXT file or paste its text." }, status: :unprocessable_entity
        end

        private

        def policy
          @policy ||= Mia::PersonaStudioPolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def scoped_session
          persona = policy.editable_personas.find(params[:persona_id])
          CoachPersonaSetupSession.find_by!(
            id: params[:setup_session_id] || params[:id],
            coach_persona_id: persona.id,
            coach_workspace_id: current_coach_workspace.id,
            created_by_user_id: current_user.id
          )
        end

        def proposal_resolver
          Mia::PersonaSetup::ProposalResolver.new
        end

        def not_found
          render json: { error: "Persona setup session not found.", code: "persona_setup_not_found" }, status: :not_found
        end
      end
    end
  end
end
