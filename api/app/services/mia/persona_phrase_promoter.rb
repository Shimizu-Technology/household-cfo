# frozen_string_literal: true

module Mia
  class PersonaPhrasePromoter
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

    def promote!(persona_id:, proposal_id:, expected_draft_revision:)
      ApplicationRecord.transaction do
        authorization = authorize!
        persona = locked_persona!(authorization.workspace, persona_id)
        promotion = CoachPersonaPhrasePromotion.lock.find_by(
          coach_persona_id: persona.id,
          coach_phrase_proposal_id: proposal_id
        )
        return promotion if promotion&.integrity_valid? && active_exact_artifact?(persona, promotion)

        verify_revision!(persona, expected_draft_revision)
        proposal_identity = CoachPhraseProposal.find_by!(id: proposal_id, coach_workspace_id: authorization.workspace.id)
        source = CoachContentSource.lock.find(proposal_identity.coach_content_source_id)
        version = CoachContentItemVersion.find(proposal_identity.coach_content_item_version_id)
        CoachContentItem.lock.find(version.coach_content_item_id)
        CoachContentItemVersion.lock.find(version.id)
        proposal = CoachPhraseProposal.lock.find_by!(id: proposal_identity.id, coach_workspace_id: authorization.workspace.id)
        attestation = CoachPhraseAttestation.lock.find_by!(coach_phrase_proposal_id: proposal.id, decision: "approved")
        unless proposal.integrity_valid? && proposal.status == "submitted" && attestation.integrity_valid?
          raise Error.new("This phrase does not have a valid approval.", code: "phrase_promotion_unapproved")
        end
        verify_evidence!(authorization.workspace, source, proposal)

        promotion ||= create_promotion!(persona:, proposal:, attestation:, actor: authorization.actor)
        raise Error.new("The approved phrase audit chain is invalid.", code: "phrase_promotion_invalid") unless promotion.integrity_valid?

        apply_promotion!(persona:, promotion:, actor: authorization.actor)
        promotion
      end
    rescue ActiveRecord::RecordNotFound
      raise Error.new("Approved phrase or persona not found.", code: "phrase_promotion_not_found")
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_promotion_invalid")
    rescue PhraseEvidenceVerifier::Error => error
      raise Error.new(error.message, code: error.code)
    end

    def restore!(persona_id:, promotion_id:, expected_draft_revision:)
      ApplicationRecord.transaction do
        authorization = authorize!
        persona = locked_persona!(authorization.workspace, persona_id)
        promotion = CoachPersonaPhrasePromotion.lock.find_by!(id: promotion_id, coach_persona_id: persona.id)
        raise Error.new("The approved phrase audit chain is invalid.", code: "phrase_promotion_invalid") unless promotion.integrity_valid?
        return promotion if active_exact_artifact?(persona, promotion)

        verify_revision!(persona, expected_draft_revision)
        apply_promotion!(persona:, promotion:, actor: authorization.actor)
        promotion
      end
    rescue ActiveRecord::RecordNotFound
      raise Error.new("Approved phrase or persona not found.", code: "phrase_promotion_not_found")
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "phrase_promotion_invalid")
    end

    private

    attr_reader :actor_id, :workspace_id

    def authorize!
      ApprovedPhraseAuthorization.lock!(actor_id:, workspace_id:, permission: :review) ||
        raise(Error.new("Approved phrase or persona not found.", code: "phrase_promotion_not_found"))
    end

    def locked_persona!(workspace, persona_id)
      persona = CoachPersona.lock.find_by!(id: persona_id, coach_workspace_id: workspace.id)
      raise Error.new("Archived personas are read-only.", code: "persona_archived") if persona.archived?

      persona
    end

    def verify_revision!(persona, expected)
      return if Integer(expected, exception: false) == persona.draft_revision

      raise Error.new("The persona changed; reload it before promoting this phrase.", code: "persona_draft_conflict")
    end

    def active_exact_artifact?(persona, promotion)
      Array(Mia::PersonaSchema.normalize(persona.draft_config)["phrases"]).any? do |phrase|
        phrase.is_a?(Hash) && phrase["artifact_id"] == promotion.artifact_id.to_s && phrase == promotion.artifact
      end
    end

    def create_promotion!(persona:, proposal:, attestation:, actor:)
      promoted_at = Time.current
      artifact = PersonaSchema.build_approved_source_artifact(
        proposal.phrase_payload,
        artifact_id: SecureRandom.uuid,
        source_user_id: actor.id,
        source_role_at_capture: actor.role
      )
      promotion = CoachPersonaPhrasePromotion.new(
        coach_persona: persona,
        coach_phrase_proposal: proposal,
        coach_phrase_attestation: attestation,
        promoted_by_user: actor,
        artifact_id: artifact.fetch("artifact_id"),
        artifact: artifact,
        artifact_fingerprint: artifact.fetch("fingerprint"),
        promoted_at: promoted_at
      )
      promotion.promotion_digest = CoachPersonaPhrasePromotion.digest_for(
        persona_id: persona.id,
        proposal:,
        attestation:,
        artifact:,
        promoted_by_user_id: actor.id,
        promoted_at:
      )
      promotion.save!
      promotion
    end

    def verify_evidence!(workspace, source, proposal)
      evidence = PhraseEvidenceVerifier.new(
        workspace: workspace,
        source: source,
        attempt: proposal.coach_content_source_attempt,
        candidate: proposal.coach_content_source_candidate,
        content_item_version: proposal.coach_content_item_version,
        phrase_payload: proposal.phrase_payload
      ).call
      fields = %i[
        phrase_payload evidence_locator evidence_start_byte evidence_end_byte source_checksum_sha256
        source_segment_digest phrase_digest approved_content_digest source_provenance_digest
      ]
      return if fields.all? { |field| proposal.public_send(field) == evidence.public_send(field) }

      raise Error.new("The exact source evidence changed after review.", code: "phrase_promotion_evidence_changed")
    end

    def apply_promotion!(persona:, promotion:, actor:)
      config = PersonaSchema.normalize(persona.draft_config).deep_dup
      phrases = Array(config["phrases"])
      existing = phrases.find { |phrase| phrase.is_a?(Hash) && phrase["artifact_id"] == promotion.artifact_id.to_s }
      return persona if existing == promotion.artifact
      raise Error.new("This approved phrase conflicts with an existing artifact.", code: "phrase_promotion_conflict") if existing

      phrases << promotion.artifact.deep_dup
      config["phrases"] = phrases
      PersonaSchema.validate!(config)
      persona.apply_authoring_state!(description: persona.description, draft_config: config)
      stale_setup_proposals!(persona, actor)
      persona
    rescue PersonaSchema::InvalidConfiguration => error
      raise Error.new(error.errors.first, code: "phrase_promotion_invalid")
    end

    def stale_setup_proposals!(persona, actor)
      CoachPersonaSetupProposal.joins(:session)
        .where(coach_persona_setup_sessions: { coach_persona_id: persona.id }, status: "pending")
        .order(:id).lock.each { |proposal| proposal.resolve!(status: "stale", actor: actor) }
    end
  end
end
