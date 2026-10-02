# frozen_string_literal: true

module Mia
  class PersonaRollback
    class RollbackError < StandardError; end

    def initialize(persona:, target_version:, actor:)
      @persona = persona
      @target_version = target_version
      @actor = actor
    end

    def call(expected_current_version_id:, expected_draft_revision:)
      ensure_staff!
      persona.with_lock do
        raise RollbackError, "Archived personas cannot be rolled back" if persona.archived?
        unless Integer(expected_draft_revision, exception: false) == persona.draft_revision
          raise RollbackError, "The persona draft changed; reload it before rolling back"
        end
        unless normalized_version_id(expected_current_version_id) == persona.current_published_version_id
          raise RollbackError, "The published persona changed; reload it before rolling back"
        end
        raise RollbackError, "Rollback target must belong to this persona" unless target_version.coach_persona_id == persona.id
        if persona.release_gate_version == "gate_v2" && target_version.release_gate_version != "gate_v2"
          raise RollbackError, "A gate_v2 persona cannot roll back to legacy release evidence"
        end
        ensure_target_is_safe!
        raise RollbackError, "Rollback target content manifest is invalid" unless target_version.content_manifest_valid?
        raise RollbackError, "Rollback target phrase manifest is invalid" unless target_version.phrase_manifest_valid?
        raise RollbackError, "Rollback target release evidence is invalid" unless target_version.release_evidence_valid?

        version = persona.versions.create!(
          version_number: persona.versions.maximum(:version_number).to_i + 1,
          config: target_version.config.deep_dup,
          config_digest: target_version.config_digest,
          content_manifest_digest: CoachPersonaVersion.content_manifest_digest_for([]),
          phrase_manifest_digest: Mia::PhraseManifest.digest_for([]),
          published_by_user: actor,
          source_version: target_version,
          release_gate_version: target_version.release_gate_version,
          release_candidate: target_version.release_candidate,
          evaluation_run: target_version.evaluation_run,
          evaluation_approval: target_version.evaluation_approval,
          release_manifest_digest: target_version.release_manifest_digest,
          audience_digest: target_version.audience_digest,
          release_evidence_digest: target_version.release_evidence_digest
        )
        target_version.content_pack_links.includes(:coach_content_pack_version).order(:position).each do |link|
          version.content_pack_links.create!(coach_content_pack_version: link.coach_content_pack_version, position: link.position)
        end
        target_version.phrase_artifact_links.includes(:coach_persona_phrase_promotion).order(:position).each do |link|
          version.phrase_artifact_links.create!(
            coach_persona_phrase_promotion: link.coach_persona_phrase_promotion,
            position: link.position,
            artifact_id: link.artifact_id,
            artifact_fingerprint: link.artifact_fingerprint,
            promotion_digest: link.promotion_digest
          )
        end
        version.seal_manifests!
        raise RollbackError, "Rollback target release evidence no longer matches" unless version.release_evidence_valid?
        persona.draft_content_pack_links.delete_all
        version.content_pack_links.includes(:coach_content_pack_version).order(:position).each do |link|
          persona.draft_content_pack_links.create!(coach_content_pack_version: link.coach_content_pack_version, position: link.position)
        end
        persona.apply_rollback_version!(version)
        persona.cohort_persona_assignments.update_all(
          coach_persona_version_id: version.id,
          updated_at: Time.current
        )
        persona.publication_events.create!(
          coach_persona_version: version,
          actor_user: actor,
          event_type: "rollback",
          source_version: target_version,
          release_gate_version: version.release_gate_version,
          release_evidence_digest: version.release_evidence_digest
        )
        version
      end
    end

    private

    attr_reader :persona, :target_version, :actor

    def ensure_staff!
      unless persona.coach_workspace&.allows?(actor, :publish)
        raise RollbackError, "Only a workspace owner or reviewer can roll back a persona"
      end
    end

    def ensure_target_is_safe!
      PersonaSchema.validate!(target_version.config)
    rescue PersonaSchema::InvalidConfiguration
      raise RollbackError, "Rollback target no longer meets the current persona safety rules"
    end

    def normalized_version_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
