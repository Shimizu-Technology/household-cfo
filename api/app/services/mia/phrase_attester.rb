# frozen_string_literal: true

module Mia
  class PhraseAttester
    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    def initialize(actor:, workspace:)
      @actor_id = actor.id
      @workspace_id = workspace&.id
    end

    def call!(proposal_id:, decision:, expected_digest:)
      ApplicationRecord.transaction do
        authorization = authorize!
        proposal_identity = CoachPhraseProposal.find_by!(id: proposal_id, coach_workspace_id: authorization.workspace.id)
        source = CoachContentSource.lock.find(proposal_identity.coach_content_source_id)
        proposal = CoachPhraseProposal.lock.find_by!(id: proposal_identity.id, coach_workspace_id: authorization.workspace.id)
        existing = CoachPhraseAttestation.lock.find_by(coach_phrase_proposal_id: proposal.id)
        return existing if existing && existing.decision == decision.to_s && secure_match?(existing.proposal_digest, expected_digest)
        raise Error.new("This phrase proposal was already reviewed.", code: "phrase_attestation_exists") if existing

        unless proposal.status == "submitted" && secure_match?(proposal.proposal_digest, expected_digest)
          raise Error.new("The phrase proposal changed or is no longer awaiting review.", code: "phrase_attestation_conflict")
        end
        unless decision.to_s.in?(CoachPhraseAttestation::DECISIONS)
          raise Error.new("Choose approve or reject.", code: "phrase_attestation_invalid")
        end

        self_review = self_review?(authorization, proposal)
        evidence = PhraseEvidenceVerifier.new(
          workspace: authorization.workspace,
          source: source,
          attempt: proposal.coach_content_source_attempt,
          candidate: proposal.coach_content_source_candidate,
          content_item_version: proposal.coach_content_item_version,
          phrase_payload: proposal.phrase_payload
        ).call
        unless evidence_matches?(proposal, evidence)
          raise Error.new("The exact source evidence changed after submission.", code: "phrase_attestation_evidence_changed")
        end

        reviewed_at = Time.current
        attestation = CoachPhraseAttestation.new(
          coach_phrase_proposal: proposal,
          reviewed_by_user: authorization.actor,
          decision: decision.to_s,
          self_review: self_review,
          proposal_digest: proposal.proposal_digest,
          evidence_digest: proposal.evidence_digest,
          reviewed_at: reviewed_at
        )
        attestation.attestation_digest = CoachPhraseAttestation.digest_for(
          proposal:,
          reviewer_id: authorization.actor.id,
          decision: decision.to_s,
          self_review:,
          reviewed_at:
        )
        attestation.save!
        proposal.update!(status: "rejected") if decision.to_s == "rejected"
        attestation
      end
    rescue ActiveRecord::RecordNotFound
      raise Error.new("Phrase proposal not found.", code: "phrase_proposal_not_found")
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_attestation_invalid")
    rescue PhraseEvidenceVerifier::Error => error
      raise Error.new(error.message, code: error.code)
    end

    private

    attr_reader :actor_id, :workspace_id

    def authorize!
      ApprovedPhraseAuthorization.lock!(actor_id:, workspace_id:, permission: :review) ||
        raise(Error.new("Phrase proposal not found.", code: "phrase_proposal_not_found"))
    end

    def self_review?(authorization, proposal)
      return false unless proposal.proposed_by_user_id == authorization.actor.id

      membership = authorization.workspace.membership_for(authorization.actor)
      eligible = membership&.role == "owner" &&
        !authorization.workspace.coach_workspace_memberships.where(role: %w[owner reviewer]).where.not(user_id: authorization.actor.id).exists?
      unless eligible
        raise Error.new("A different workspace owner or reviewer must review this phrase.", code: "phrase_self_review_not_allowed")
      end
      true
    end

    def evidence_matches?(proposal, evidence)
      fields = %i[
        phrase_payload evidence_locator evidence_start_byte evidence_end_byte source_checksum_sha256
        source_segment_digest phrase_digest approved_content_digest source_provenance_digest
      ]
      fields.all? { |field| proposal.public_send(field) == evidence.public_send(field) }
    end

    def secure_match?(left, right)
      left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end
  end
end
