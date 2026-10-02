# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachPhraseProposalsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!
        rescue_from ActiveRecord::RecordNotFound, with: :not_found

        def index
          proposals = policy.visible_proposals.where(coach_content_source_id: params[:content_source_id])
            .includes(:proposed_by_user, :persona_promotions, attestation: :reviewed_by_user).order(created_at: :desc)
          render json: { phrase_proposals: proposals.map { |proposal| serializer.proposal(proposal) }, permissions: policy.permissions }
        end

        def show
          render json: { phrase_proposal: serializer.proposal(visible_proposal) }
        end

        def create
          raise Mia::PhraseProposalWriter::Error.new("Phrase proposal not permitted.", code: "phrase_proposal_forbidden") unless policy.can_propose?

          proposal = writer.create!(
            source_id: params[:content_source_id],
            candidate_id: phrase_params.fetch(:candidate_id),
            content_item_version_id: phrase_params.fetch(:content_item_version_id),
            phrase_payload: phrase_params.fetch(:phrase)
          )
          render json: { phrase_proposal: serializer.proposal(proposal) }, status: :created
        rescue ActionController::ParameterMissing, KeyError
          render_error("Complete the approved phrase fields.", "phrase_payload_invalid", :unprocessable_entity)
        rescue Mia::PhraseProposalWriter::Error => error
          render_writer_error(error)
        end

        def update
          proposal = writer.update!(
            proposal_id: params[:id],
            expected_revision: phrase_params.fetch(:revision),
            expected_digest: phrase_params.fetch(:digest),
            phrase_payload: phrase_params.fetch(:phrase)
          )
          render json: { phrase_proposal: serializer.proposal(proposal) }
        rescue ActionController::ParameterMissing, KeyError
          render_error("Complete the approved phrase fields.", "phrase_payload_invalid", :unprocessable_entity)
        rescue Mia::PhraseProposalWriter::Error => error
          render_writer_error(error)
        end

        def submit
          proposal = writer.submit!(
            proposal_id: params[:id],
            expected_revision: params.dig(:phrase_proposal, :revision),
            expected_digest: params.dig(:phrase_proposal, :digest)
          )
          render json: { phrase_proposal: serializer.proposal(proposal) }
        rescue Mia::PhraseProposalWriter::Error => error
          render_writer_error(error)
        end

        private

        def policy
          @policy ||= Mia::ApprovedPhrasePolicy.new(current_user, workspace: coach_workspace_for_policy)
        end

        def serializer
          @serializer ||= Mia::ApprovedPhraseSerializer.new(policy: policy)
        end

        def writer
          @writer ||= Mia::PhraseProposalWriter.new(actor: current_user, workspace: coach_workspace_for_policy)
        end

        def visible_proposal
          @visible_proposal ||= policy.visible_proposals.includes(:proposed_by_user, :persona_promotions, attestation: :reviewed_by_user).find(params[:id])
        end

        def phrase_params
          @phrase_params ||= params.require(:phrase_proposal).permit(
            :candidate_id, :content_item_version_id, :revision, :digest,
            phrase: [ :text, :meaning, :frequency, :caution, { allowed_contexts: [], prohibited_contexts: [] } ]
          ).to_h.deep_symbolize_keys
        end

        def render_writer_error(error)
          status = error.code.in?(%w[phrase_proposal_conflict]) ? :conflict :
            error.code.in?(%w[phrase_source_not_found phrase_proposal_not_found]) ? :not_found : :unprocessable_entity
          render_error(error.message, error.code, status)
        end

        def not_found
          render_error("Phrase proposal not found.", "phrase_proposal_not_found", :not_found)
        end

        def render_error(message, code, status)
          render json: { error: message, errors: [ message ], code: code }, status: status
        end
      end
    end
  end
end
