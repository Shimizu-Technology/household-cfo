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
      ensure_editor!
      persona.with_lock do
        validate_request!(expected_current_version_id:, expected_draft_revision:)
        validate_target!
        reject_noop_restore!

        previous_revision = persona.draft_revision
        persona.restore_version_to_draft!(target_version)
        restore_event!(previous_revision)
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      raise RollbackError, error.message
    end

    private

    attr_reader :persona, :target_version, :actor

    def ensure_editor!
      return if persona.coach_workspace&.allows?(actor, :edit)

      raise RollbackError, "Only a workspace owner or editor can restore a persona version to the draft"
    end

    def validate_request!(expected_current_version_id:, expected_draft_revision:)
      raise RollbackError, "Archived personas cannot restore a version to the draft" if persona.archived?
      unless Integer(expected_draft_revision, exception: false) == persona.draft_revision
        raise RollbackError, "The persona draft changed; reload it before restoring this version"
      end
      unless normalized_version_id(expected_current_version_id) == persona.current_published_version_id
        raise RollbackError, "The published persona changed; reload it before restoring this version"
      end
      raise RollbackError, "Restore target must belong to this persona" unless target_version.coach_persona_id == persona.id
      if target_version.id == persona.current_published_version_id
        raise RollbackError, "The current published version cannot be restored to the draft"
      end
    end

    def validate_target!
      PersonaSchema.validate!(target_version.config)
      raise RollbackError, "Restore target content manifest is invalid" unless target_version.content_manifest_valid?
      raise RollbackError, "Restore target phrase manifest is invalid" unless target_version.phrase_manifest_valid?
    rescue PersonaSchema::InvalidConfiguration
      raise RollbackError, "Restore target no longer meets the current persona safety rules"
    end

    def reject_noop_restore!
      same = PersonaSchema.digest(persona.draft_config) == target_version.config_digest &&
        persona.draft_content_manifest_digest == target_version.content_manifest_digest &&
        persona.draft_phrase_manifest_digest == target_version.phrase_manifest_digest
      raise RollbackError, "The draft already matches this version" if same
    end

    def restore_event!(previous_revision)
      event = persona.draft_restore_events.new(
        source_version: target_version,
        actor_user: actor,
        previous_draft_revision: previous_revision,
        restored_draft_revision: persona.draft_revision,
        config_digest: target_version.config_digest,
        content_manifest_digest: target_version.content_manifest_digest,
        phrase_manifest_digest: target_version.phrase_manifest_digest,
        content_pack_version_ids: target_version.content_pack_links.order(:position).pluck(:coach_content_pack_version_id),
        phrase_artifacts_snapshot: Array(target_version.config["phrases"]),
        restored_at: Time.current
      )
      event.event_digest = CoachPersonaDraftRestoreEvent.digest_for(event)
      event.save!
      event
    end

    def normalized_version_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
