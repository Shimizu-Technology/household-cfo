# frozen_string_literal: true

require "digest"
require "json"

module Branding
  class Publisher
    class PublicationError < StandardError; end
    class PreviewRequiredError < PublicationError; end

    def initialize(configuration:, actor:)
      @configuration = configuration
      @actor = actor
    end

    def preview!(expected_draft_revision:)
      configuration.with_lock do
        ensure_preview_permission!
        validate_revision!(expected_draft_revision)
        digest = preview_digest
        configuration.update!(
          preview_digest: digest,
          previewed_draft_revision: configuration.draft_revision,
          previewed_at: Time.current
        )
        digest
      end
    end

    def publish!(expected_preview_digest:, expected_draft_revision:, expected_current_version_id:, idempotency_key:)
      fingerprint = request_fingerprint(
        action: "publish",
        preview_digest: expected_preview_digest,
        draft_revision: expected_draft_revision,
        current_version_id: expected_current_version_id
      )

      configuration.with_lock do
        replay = replay_for(idempotency_key, fingerprint)
        return replay if replay

        ensure_publish_permission!
        validate_revision!(expected_draft_revision)
        unless normalized_id(expected_current_version_id) == configuration.current_published_version_id
          raise PublicationError, "The published brand changed; reload before publishing"
        end
        unless expected_preview_digest.present? &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, configuration.preview_digest.to_s) &&
            ActiveSupport::SecurityUtils.secure_compare(expected_preview_digest.to_s, preview_digest) &&
            configuration.previewed_at.present? &&
            configuration.previewed_draft_revision == configuration.draft_revision
          raise PreviewRequiredError, "Preview this exact brand draft before publishing"
        end

        version = configuration.versions.create!(
          coach_workspace: configuration.coach_workspace,
          version_number: configuration.versions.maximum(:version_number).to_i + 1,
          config: configuration.draft_config.deep_dup,
          config_digest: Schema.digest(configuration.draft_config),
          published_by_user: actor
        )
        configuration.update!(current_published_version: version)
        configuration.publication_events.create!(
          coach_workspace: configuration.coach_workspace,
          workspace_brand_version: version,
          actor_user: actor,
          event_type: "publish",
          idempotency_key: idempotency_key,
          request_fingerprint: fingerprint
        )
        version
      end
    rescue ActiveRecord::RecordNotUnique
      configuration.reload
      replay_for(idempotency_key, fingerprint) || raise
    end

    private

    attr_reader :configuration, :actor

    def ensure_preview_permission!
      return if Policy.new(actor, workspace: configuration.coach_workspace).preview?

      raise PublicationError, "Only a workspace owner, editor, or reviewer can preview branding"
    end

    def ensure_publish_permission!
      return if Policy.new(actor, workspace: configuration.coach_workspace).publish?

      raise PublicationError, "Only a workspace owner or reviewer can publish branding"
    end

    def validate_revision!(value)
      return if Integer(value, exception: false) == configuration.draft_revision

      raise PublicationError, "The brand draft changed; reload before continuing"
    end

    def preview_digest
      Schema.preview_digest(configuration.draft_config, draft_revision: configuration.draft_revision)
    end

    def normalized_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end

    def request_fingerprint(payload)
      Digest::SHA256.hexdigest(JSON.generate(payload.stringify_keys.sort.to_h))
    end

    def replay_for(idempotency_key, fingerprint)
      event = configuration.publication_events.find_by(idempotency_key: idempotency_key)
      return nil unless event
      unless ActiveSupport::SecurityUtils.secure_compare(event.request_fingerprint, fingerprint)
        raise PublicationError, "This idempotency key was already used for a different brand publication"
      end

      event.workspace_brand_version
    end
  end
end
