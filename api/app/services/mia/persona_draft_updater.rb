# frozen_string_literal: true

require "digest"
require "json"

module Mia
  class PersonaDraftUpdater
    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    def self.state_for(persona)
      {
        "description" => persona.description.to_s,
        "draft_config" => PersonaSchema.normalize(persona.draft_config)
      }
    end

    def self.state_digest(state)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(PersonaSchema.normalize(state))).b)
    end

    def self.canonicalize(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
      when Array
        value.map { |child| canonicalize(child) }
      else
        value
      end
    end

    def initialize(persona:, actor:, workspace:, origin_proposal_id: nil, allow_phrase_artifact_edits: true)
      @persona = persona
      @actor = actor
      @workspace = workspace
      @origin_proposal_id = origin_proposal_id
      @allow_phrase_artifact_edits = allow_phrase_artifact_edits
    end

    def call!(expected_draft_revision:, description:, draft_config:, prepared: false, expected_state_digest: nil, reject_noop: true)
      ApplicationRecord.transaction do
        authorization = PersonaSetup::Authorization.lock_editor!(
          actor_id: actor.id,
          workspace_id: workspace&.id,
          persona_id: persona.id
        )
        raise Error.new("Persona not found.", code: "persona_not_found") unless authorization

        @authorized_actor = authorization.actor
        @persona = authorization.persona
        apply_locked!(
          expected_draft_revision:,
          description:,
          draft_config:,
          prepared:,
          expected_state_digest:,
          reject_noop:
        )
      end
      persona.reload
    end

    def apply_locked!(expected_draft_revision:, description:, draft_config:, prepared: false, expected_state_digest: nil, reject_noop: true)
      authorize! unless authorized_actor
      raise Error.new("Archived personas are read-only. Restore this persona before editing it.", code: "persona_archived") if persona.archived?
      unless Integer(expected_draft_revision, exception: false) == persona.draft_revision
        raise Error.new("This persona changed in another session. Reload the current draft before saving.", code: "persona_draft_conflict")
      end

      normalized_description = description.to_s.strip
      normalized_config = if prepared
        validate_prepared_config!(draft_config)
      else
        PersonaSchema.prepare_draft_artifacts(
          draft_config,
          source_user_id: authorized_actor.id,
          source_role_at_capture: authorized_actor.role,
          existing_configuration: persona.draft_config,
          allow_coach_artifact_edits: allow_phrase_artifact_edits
        )
      end
      normalized_config = PersonaSchema.validate!(normalized_config)
      next_state = { "description" => normalized_description, "draft_config" => normalized_config }
      if expected_state_digest && !secure_match?(expected_state_digest, self.class.state_digest(next_state))
        raise Error.new("The reviewed persona proposal no longer matches its sealed draft.", code: "persona_setup_tampered")
      end
      if self.class.state_digest(next_state) == self.class.state_digest(self.class.state_for(persona))
        raise Error.new("This proposal does not change the persona draft.", code: "persona_setup_no_change") if reject_noop

        return persona
      end

      persona.apply_authoring_state!(description: normalized_description, draft_config: normalized_config)
      stale_other_pending_proposals!
      persona
    rescue PersonaSchema::InvalidConfiguration => error
      raise Error.new(error.errors.first, code: "persona_invalid")
    rescue ActiveRecord::RecordInvalid => error
      raise Error.new(error.record.errors.full_messages.first, code: "persona_invalid")
    end

    private

    attr_reader :persona, :actor, :workspace, :origin_proposal_id, :authorized_actor, :allow_phrase_artifact_edits

    def authorize!
      authorization = PersonaSetup::Authorization.lock_editor!(
        actor_id: actor.id,
        workspace_id: workspace&.id,
        persona_id: persona.id
      )
      raise Error.new("Persona not found.", code: "persona_not_found") unless authorization

      @authorized_actor = authorization.actor
      @persona = authorization.persona
    end

    def validate_prepared_config!(configuration)
      normalized = PersonaSchema.normalize(configuration)
      existing_participant = participant_artifacts(persona.draft_config)
      submitted_participant = participant_artifacts(normalized)
      unless existing_participant == submitted_participant
        raise Error.new("Participant-supplied phrase artifacts cannot be changed by setup chat.", code: "persona_setup_phrase_locked")
      end
      existing_approved = approved_source_artifacts(persona.draft_config)
      submitted_approved = approved_source_artifacts(normalized)
      unless submitted_approved.all? { |artifact_id, artifact| existing_approved[artifact_id] == artifact }
        raise Error.new("Approved-source phrase artifacts cannot be created or changed by setup chat.", code: "persona_setup_phrase_locked")
      end
      existing_by_id = Array(PersonaSchema.normalize(persona.draft_config).to_h["phrases"])
        .select { |phrase| phrase.is_a?(Hash) }.index_by { |phrase| phrase["artifact_id"] }
      Array(normalized["phrases"]).each do |phrase|
        next unless phrase.is_a?(Hash)
        next if phrase["provenance"] == "participant_supplied"
        next if existing_by_id[phrase["artifact_id"]] == phrase

        unless phrase["provenance"] == "coach_authored" && phrase["source_user_id"] == authorized_actor.id &&
            phrase["source_role_at_capture"].in?(%w[coach admin]) &&
            phrase["fingerprint"] == PersonaSchema.artifact_fingerprint(phrase)
          raise Error.new("Coach-authored phrase provenance does not match the current editor.", code: "persona_setup_phrase_tampered")
        end
      end
      normalized
    end

    def participant_artifacts(configuration)
      Array(PersonaSchema.normalize(configuration).to_h["phrases"])
        .select { |phrase| phrase.is_a?(Hash) && phrase["provenance"] == "participant_supplied" }
    end

    def approved_source_artifacts(configuration)
      Array(PersonaSchema.normalize(configuration).to_h["phrases"])
        .select { |phrase| phrase.is_a?(Hash) && phrase["provenance"] == "approved_source" }
        .index_by { |phrase| phrase["artifact_id"] }
    end

    def stale_other_pending_proposals!
      scope = CoachPersonaSetupProposal.joins(:session)
        .where(coach_persona_setup_sessions: { coach_persona_id: persona.id }, status: "pending")
      scope = scope.where.not(id: origin_proposal_id) if origin_proposal_id
      scope.order(:id).lock.each { |proposal| proposal.resolve!(status: "stale", actor: authorized_actor) }
    end

    def secure_match?(left, right)
      left.to_s.bytesize == right.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end
  end
end
