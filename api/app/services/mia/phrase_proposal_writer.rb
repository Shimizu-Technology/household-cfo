# frozen_string_literal: true

module Mia
  class PhraseProposalWriter
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

    def create!(source_id:, candidate_id:, content_item_version_id:, phrase_payload:)
      ApplicationRecord.transaction do
        authorization = authorize!
        chain = lock_chain!(authorization.workspace, source_id:, candidate_id:, content_item_version_id:)
        evidence = verify!(authorization.workspace, chain, phrase_payload)
        proposal = CoachPhraseProposal.new(
          coach_workspace: authorization.workspace,
          coach_content_source: chain.fetch(:source),
          coach_content_source_attempt: chain.fetch(:attempt),
          coach_content_source_candidate: chain.fetch(:candidate),
          coach_content_item_version: chain.fetch(:version),
          proposed_by_user: authorization.actor,
          **evidence.to_h
        )
        proposal.proposal_digest = CoachPhraseProposal.digest_for(proposal)
        proposal.save!
        proposal
      end
    rescue ActiveRecord::RecordNotFound
      raise Error.new("Approved phrase source not found.", code: "phrase_source_not_found")
    rescue ActiveRecord::RecordNotUnique
      raise Error.new("This exact phrase proposal already exists.", code: "phrase_proposal_duplicate")
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_proposal_invalid")
    rescue PhraseEvidenceVerifier::Error => error
      raise Error.new(error.message, code: error.code)
    end

    def update!(proposal_id:, expected_revision:, expected_digest:, phrase_payload:)
      ApplicationRecord.transaction do
        authorization = authorize!
        proposal = locked_proposal_with_source!(authorization.workspace, proposal_id)
        verify_cas!(proposal, expected_revision, expected_digest)
        raise Error.new("Only draft phrase proposals can be changed.", code: "phrase_proposal_sealed") unless proposal.status == "draft"

        chain = chain_for(proposal)
        evidence = verify!(authorization.workspace, chain, phrase_payload)
        proposal.assign_attributes(**evidence.to_h, revision: proposal.revision + 1)
        proposal.proposal_digest = CoachPhraseProposal.digest_for(proposal)
        proposal.save!
        proposal
      end
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_proposal_invalid")
    rescue PhraseEvidenceVerifier::Error => error
      raise Error.new(error.message, code: error.code)
    end

    def submit!(proposal_id:, expected_revision:, expected_digest:)
      ApplicationRecord.transaction do
        authorization = authorize!
        proposal = locked_proposal_with_source!(authorization.workspace, proposal_id)
        return proposal if proposal.status == "submitted" && secure_match?(proposal.proposal_digest, expected_digest)

        verify_cas!(proposal, expected_revision, expected_digest)
        raise Error.new("Only draft phrase proposals can be submitted.", code: "phrase_proposal_sealed") unless proposal.status == "draft"

        evidence = verify!(authorization.workspace, chain_for(proposal), proposal.phrase_payload)
        proposal.assign_attributes(**evidence.to_h, revision: proposal.revision + 1, status: "submitted", submitted_at: Time.current)
        proposal.proposal_digest = CoachPhraseProposal.digest_for(proposal)
        proposal.save!
        proposal
      end
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_proposal_invalid")
    rescue PhraseEvidenceVerifier::Error => error
      raise Error.new(error.message, code: error.code)
    end

    private

    attr_reader :actor_id, :workspace_id

    def authorize!
      ApprovedPhraseAuthorization.lock!(actor_id:, workspace_id:, permission: :edit) ||
        raise(Error.new("Approved phrase source not found.", code: "phrase_source_not_found"))
    end

    def lock_chain!(workspace, source_id:, candidate_id:, content_item_version_id:)
      source = CoachContentSource.lock.find_by!(id: source_id, scope: "coach", coach_workspace_id: workspace.id)
      candidate = source.candidates.lock.find(candidate_id)
      attempt = source.attempts.lock.find(candidate.coach_content_source_attempt_id)
      version = CoachContentItemVersion.includes(:coach_content_item, source_provenance: %i[
        coach_content_source coach_content_source_attempt coach_content_source_candidate
      ]).lock.find(content_item_version_id)
      { source:, attempt:, candidate:, version: }
    end

    def locked_proposal_with_source!(workspace, proposal_id)
      identity = CoachPhraseProposal.find_by!(id: proposal_id, coach_workspace_id: workspace.id, proposed_by_user_id: actor_id)
      CoachContentSource.lock.find(identity.coach_content_source_id)
      CoachPhraseProposal.lock.find(identity.id)
    rescue ActiveRecord::RecordNotFound
      raise Error.new("Phrase proposal not found.", code: "phrase_proposal_not_found")
    end

    def chain_for(proposal)
      {
        source: proposal.coach_content_source,
        attempt: proposal.coach_content_source_attempt,
        candidate: proposal.coach_content_source_candidate,
        version: proposal.coach_content_item_version
      }
    end

    def verify!(workspace, chain, phrase_payload)
      PhraseEvidenceVerifier.new(
        workspace:,
        source: chain.fetch(:source),
        attempt: chain.fetch(:attempt),
        candidate: chain.fetch(:candidate),
        content_item_version: chain.fetch(:version),
        phrase_payload:
      ).call
    end

    def verify_cas!(proposal, revision, digest)
      valid = Integer(revision, exception: false) == proposal.revision && secure_match?(proposal.proposal_digest, digest)
      raise Error.new("The phrase proposal changed; reload it before continuing.", code: "phrase_proposal_conflict") unless valid
    end

    def secure_match?(left, right)
      left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end
  end
end
