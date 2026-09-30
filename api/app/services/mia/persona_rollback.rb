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

        version = persona.versions.create!(
          version_number: persona.versions.maximum(:version_number).to_i + 1,
          config: target_version.config.deep_dup,
          config_digest: target_version.config_digest,
          published_by_user: actor,
          source_version: target_version
        )
        persona.update!(current_published_version: version)
        persona.cohort_persona_assignments.update_all(
          coach_persona_version_id: version.id,
          updated_at: Time.current
        )
        persona.publication_events.create!(
          coach_persona_version: version,
          actor_user: actor,
          event_type: "rollback",
          source_version: target_version
        )
        version
      end
    end

    private

    attr_reader :persona, :target_version, :actor

    def ensure_staff!
      raise RollbackError, "Only a coach or admin can roll back a persona" unless actor&.staff?
    end

    def normalized_version_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
