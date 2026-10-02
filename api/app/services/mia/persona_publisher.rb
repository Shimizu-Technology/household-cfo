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
        ensure_draft_is_safe!
        ensure_draft_content_manifests!
        ensure_draft_phrase_manifest!

        digest = preview_digest
        prompt = [ PersonaPromptBuilder.call(persona.draft_config), content_pack_preview ].compact_blank.join("\n\n")
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
        ensure_draft_is_safe!
        ensure_draft_content_manifests!
        promotions = ensure_draft_phrase_manifest!

        current_digest = PersonaSchema.digest(persona.draft_config)
        current_preview_digest = preview_digest
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
          content_manifest_digest: CoachPersonaVersion.content_manifest_digest_for([]),
          phrase_manifest_digest: Mia::PhraseManifest.digest_for([]),
          published_by_user: actor
        )
        persona.draft_content_pack_links.includes(:coach_content_pack_version).order(:position).each do |link|
          version.content_pack_links.create!(coach_content_pack_version: link.coach_content_pack_version, position: link.position)
        end
        promotions.each do |promotion, position|
          version.phrase_artifact_links.create!(
            coach_persona_phrase_promotion: promotion,
            position: position,
            artifact_id: promotion.artifact_id,
            artifact_fingerprint: promotion.artifact_fingerprint,
            promotion_digest: promotion.promotion_digest
          )
        end
        version.seal_manifests!
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

    def preview_digest
      PersonaPromptBuilder.digest(
        persona.draft_config,
        draft_revision: persona.draft_revision,
        content_digests: persona.draft_content_manifest_entries,
        phrase_digests: persona.draft_phrase_manifest_entries
      )
    end

    def ensure_draft_content_manifests!
      valid = persona.draft_content_pack_links.includes(coach_content_pack_version: { entries: :coach_content_item_version }).all? do |link|
        link.coach_content_pack_version.manifest_valid?
      end
      raise PublicationError, "Attached content pack is not a valid sealed publication" unless valid
    end

    def ensure_draft_phrase_manifest!
      Mia::PhraseManifest.promotions_for_config(persona)
    rescue ArgumentError
      raise PublicationError, "An approved-source phrase failed its sealed evidence check"
    end

    def ensure_draft_is_safe!
      PersonaSchema.validate!(persona.draft_config)
    rescue PersonaSchema::InvalidConfiguration
      raise PublicationError, "The persona draft no longer meets the current safety rules; review and save it again before publishing"
    end

    def content_pack_preview
      packs = persona.draft_content_pack_links.includes(:coach_content_pack_version).order(:position).map do |link|
        version = link.coach_content_pack_version
        "#{version.name} v#{version.version_number} (#{version.pack_kind}, #{version.content_digest})"
      end
      return if packs.empty?

      "Approved content packs attached to this exact draft: #{packs.join('; ')}."
    end

    def ensure_staff!
      unless persona.coach_workspace&.allows?(actor, :publish)
        raise PublicationError, "Only a workspace owner or reviewer can publish a persona"
      end
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
