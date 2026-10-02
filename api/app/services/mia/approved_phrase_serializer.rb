# frozen_string_literal: true

module Mia
  class ApprovedPhraseSerializer
    def initialize(policy:)
      @policy = policy
    end

    def proposal(proposal)
      attestation = proposal.attestation
      {
        id: proposal.id,
        source_id: proposal.coach_content_source_id,
        source_label: "Approved private source",
        content_item_version_id: proposal.coach_content_item_version_id,
        status: proposal.status,
        phrase: proposal.phrase_payload,
        revision: proposal.revision,
        digest: proposal.proposal_digest,
        submitted_at: proposal.submitted_at,
        superseded_at: proposal.superseded_at,
        proposed_by: user(proposal.proposed_by_user),
        attestation: attestation && {
          decision: attestation.decision,
          self_review: attestation.self_review,
          reviewed_at: attestation.reviewed_at,
          reviewed_by: user(attestation.reviewed_by_user)
        },
        promotion_count: proposal.persona_promotions.size,
        permissions: {
          edit: policy.can_propose? && proposal.status == "draft",
          submit: policy.can_propose? && proposal.status == "draft",
          review: policy.can_review? && proposal.status == "submitted" && attestation.nil?,
          promote: policy.can_review? && attestation&.decision == "approved"
        }
      }
    end

    def promotion(promotion)
      {
        id: promotion.id,
        persona_id: promotion.coach_persona_id,
        proposal_id: promotion.coach_phrase_proposal_id,
        artifact_id: promotion.artifact_id,
        phrase: promotion.artifact.slice(*CoachPhraseProposal::PAYLOAD_KEYS),
        source_label: "Approved private source",
        promoted_at: promotion.promoted_at,
        promoted_by: user(promotion.promoted_by_user)
      }
    end

    private

    attr_reader :policy

    def user(record)
      { id: record.id, full_name: record.full_name }
    end
  end
end
