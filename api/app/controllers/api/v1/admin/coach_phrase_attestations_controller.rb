# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CoachPhraseAttestationsController < BaseController
        before_action :authenticate_user!
        before_action :require_staff!
        before_action :require_selected_coach_workspace!

        def create
          attestation = Mia::PhraseAttester.new(actor: current_user, workspace: coach_workspace_for_policy).call!(
            proposal_id: params[:phrase_proposal_id],
            decision: params.dig(:attestation, :decision),
            expected_digest: params.dig(:attestation, :proposal_digest)
          )
          proposal = attestation.coach_phrase_proposal.reload
          render json: { phrase_proposal: serializer.proposal(proposal) }
        rescue Mia::PhraseAttester::Error => error
          status = error.code.in?(%w[phrase_proposal_not_found]) ? :not_found :
            error.code.in?(%w[phrase_attestation_conflict phrase_attestation_exists]) ? :conflict : :unprocessable_entity
          render json: { error: error.message, errors: [ error.message ], code: error.code }, status: status
        end

        private

        def serializer
          policy = Mia::ApprovedPhrasePolicy.new(current_user, workspace: coach_workspace_for_policy)
          @serializer ||= Mia::ApprovedPhraseSerializer.new(policy: policy)
        end
      end
    end
  end
end
