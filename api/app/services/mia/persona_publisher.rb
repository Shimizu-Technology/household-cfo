# frozen_string_literal: true

module Mia
  class PersonaPublisher
    class PublicationError < StandardError; end

    def initialize(persona:, actor:)
      @persona = persona
      @actor = actor
    end

    def compile_preview!(expected_draft_revision:)
      preview!(expected_draft_revision: expected_draft_revision, record: false)
    end

    def preview!(expected_draft_revision:, record: true)
      ensure_staff!
      persona.with_lock do
        raise PublicationError, "Archived personas cannot be previewed" if persona.archived?
        unless Integer(expected_draft_revision, exception: false) == persona.draft_revision
          raise PublicationError, "The persona draft changed; reload it before previewing"
        end

        digest = PersonaPromptBuilder.digest(persona.draft_config, draft_revision: persona.draft_revision)
        prompt = PersonaPromptBuilder.call(persona.draft_config)
        if record
          persona.update!(
            preview_digest: digest,
            previewed_at: Time.current,
            previewed_draft_revision: persona.draft_revision
          )
        end
        { digest: digest, prompt: prompt }
      end
    end

    def publish!(expected_preview_digest:, expected_draft_revision:, expected_current_version_id:)
      ensure_staff!
      persona.with_lock do
        raise PublicationError, "Archived personas cannot be published" if persona.archived?
        unless Integer(expected_draft_revision, exception: false) == persona.draft_revision
          raise PublicationError, "The persona draft changed; reload it before publishing"
        end
        unless normalized_version_id(expected_current_version_id) == persona.current_published_version_id
          raise PublicationError, "The published persona changed; reload it before publishing"
        end

        current_digest = PersonaSchema.digest(persona.draft_config)
        current_preview_digest = PersonaPromptBuilder.digest(persona.draft_config, draft_revision: persona.draft_revision)
        unless expected_preview_digest.present? &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, persona.preview_digest.to_s) &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, current_preview_digest) &&
            persona.previewed_at.present? && persona.previewed_draft_revision == persona.draft_revision
          raise PublicationError, "Preview this exact draft before publishing"
        end

        version = persona.versions.create!(
          version_number: persona.versions.maximum(:version_number).to_i + 1,
          config: persona.draft_config.deep_dup,
          config_digest: current_digest,
          published_by_user: actor
        )
        advance_publication!(version)
        persona.publication_events.create!(
          coach_persona_version: version,
          actor_user: actor,
          event_type: "publish"
        )
        version
      end
    end

    private

    attr_reader :persona, :actor

    def ensure_staff!
      raise PublicationError, "Only a coach or admin can publish a persona" unless actor&.staff?
    end

    def advance_publication!(version)
      persona.update!(current_published_version: version)
      persona.cohort_persona_assignments.update_all(
        coach_persona_version_id: version.id,
        updated_at: Time.current
      )
    end

    def normalized_version_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end
  end
end
