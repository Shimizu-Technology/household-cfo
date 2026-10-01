# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachContentSourceCandidatesController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :set_source_and_candidate
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def update
          @candidate.update_review!(
            candidate_params,
            actor: current_user,
            expected_revision: params.dig(:candidate, :revision),
            expected_digest: params.dig(:candidate, :digest)
          )
          render json: { candidate: serializer.candidate(@candidate.reload) }
        rescue CoachContentSourceCandidate::ReviewConflict => error
          conflict(error.message)
        rescue Mia::ContentSafetyValidator::UnsafeContent => error
          render json: { error: error.message, code: error.code, candidate: serializer.candidate(@candidate.reload) }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          invalid(error.respond_to?(:record) ? error.record.errors.full_messages.first : error.message)
        end

        def accept
          item = @candidate.accept!(
            actor: current_user,
            expected_revision: params.dig(:candidate, :revision),
            expected_digest: params.dig(:candidate, :digest)
          )
          content_serializer = Mia::ContentLibrarySerializer.new(policy: policy)
          render json: { candidate: serializer.candidate(@candidate.reload), item: content_serializer.item(item.reload) }
        rescue CoachContentSourceCandidate::ReviewConflict => error
          conflict(error.message)
        rescue Mia::ContentSafetyValidator::UnsafeContent => error
          render json: { error: error.message, code: error.code, candidate: serializer.candidate(@candidate.reload) }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          invalid(error.respond_to?(:record) ? error.record.errors.full_messages.first : error.message)
        end

        def reject
          @candidate.reject!(
            actor: current_user,
            expected_revision: params.dig(:candidate, :revision),
            expected_digest: params.dig(:candidate, :digest)
          )
          render json: { candidate: serializer.candidate(@candidate.reload) }
        rescue CoachContentSourceCandidate::ReviewConflict => error
          conflict(error.message)
        rescue ArgumentError => error
          invalid(error.message)
        end

        private

        def policy
          @policy ||= Mia::ContentLibraryPolicy.new(current_user)
        end

        def serializer
          @serializer ||= ContentSources::Serializer.new
        end

        def set_source_and_candidate
          @source = policy.editable_sources.find(params[:content_source_id])
          @candidate = @source.candidates.find(params[:id])
        end

        def candidate_params
          values = params.require(:candidate).permit(:title, :kind, :content, topics: []).to_h.symbolize_keys
          values[:topics] = Array(values[:topics]) if values.key?(:topics)
          values
        end

        def conflict(message)
          render json: { error: message, code: "content_candidate_conflict", candidate: serializer.candidate(@candidate.reload) }, status: :conflict
        end

        def invalid(message)
          render json: { error: message, code: "content_candidate_invalid", candidate: serializer.candidate(@candidate.reload) }, status: :unprocessable_entity
        end

        def not_found
          render json: { error: "Content candidate not found.", code: "content_candidate_not_found" }, status: :not_found
        end
      end
    end
  end
end
