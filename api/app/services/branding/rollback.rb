# frozen_string_literal: true

require "digest"
require "json"

module Branding
  class Rollback
    class RollbackError < StandardError; end

    def initialize(configuration:, target_version:, actor:)
      @configuration = configuration
      @target_version = target_version
      @actor = actor
    end

    def call(expected_current_version_id:, expected_draft_revision:, idempotency_key:)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate({
        action: "rollback",
        target_version_id: target_version.id,
        current_version_id: normalized_id(expected_current_version_id),
        draft_revision: Integer(expected_draft_revision, exception: false)
      }))

      configuration.with_lock do
        replay = replay_for(idempotency_key, fingerprint)
        return replay if replay

        ensure_publish_permission!
        unless Integer(expected_draft_revision, exception: false) == configuration.draft_revision
          raise RollbackError, "The brand draft changed; reload before restoring"
        end
        unless normalized_id(expected_current_version_id) == configuration.current_published_version_id
          raise RollbackError, "The published brand changed; reload before restoring"
        end
        unless target_version.workspace_brand_configuration_id == configuration.id
          raise RollbackError, "Version does not belong to this workspace"
        end

        restored = configuration.versions.create!(
          coach_workspace: configuration.coach_workspace,
          version_number: configuration.versions.maximum(:version_number).to_i + 1,
          config: target_version.config.deep_dup,
          config_digest: target_version.config_digest,
          published_by_user: actor,
          source_version: target_version
        )
        configuration.apply_rollback_version!(restored, actor: actor)
        configuration.publication_events.create!(
          coach_workspace: configuration.coach_workspace,
          workspace_brand_version: restored,
          source_version: target_version,
          actor_user: actor,
          event_type: "rollback",
          idempotency_key: idempotency_key,
          request_fingerprint: fingerprint
        )
        restored
      end
    rescue ActiveRecord::RecordNotUnique
      configuration.reload
      replay_for(idempotency_key, fingerprint) || raise
    end

    private

    attr_reader :configuration, :target_version, :actor

    def ensure_publish_permission!
      return if Policy.new(actor, workspace: configuration.coach_workspace).publish?

      raise RollbackError, "Only a workspace owner or reviewer can restore branding"
    end

    def normalized_id(value)
      return nil if value.blank?

      Integer(value, exception: false) || :invalid
    end

    def replay_for(idempotency_key, fingerprint)
      event = configuration.publication_events.find_by(idempotency_key: idempotency_key)
      return nil unless event
      unless ActiveSupport::SecurityUtils.secure_compare(event.request_fingerprint, fingerprint)
        raise RollbackError, "This idempotency key was already used for a different brand restore"
      end

      event.workspace_brand_version
    end
  end
end
