# frozen_string_literal: true

module Branding
  class Provisioner
    def self.ensure_for!(workspace:, actor: workspace.created_by_user)
      new(workspace: workspace, actor: actor).call
    end

    def initialize(workspace:, actor:)
      @workspace = workspace
      @actor = actor
    end

    def call
      workspace.with_lock do
        existing = workspace.workspace_brand_configuration
        return existing if existing

        configuration = workspace.create_workspace_brand_configuration!(
          draft_config: Schema::DEFAULT_CONFIG,
          last_edited_by_user: actor
        )
        version = configuration.versions.create!(
          coach_workspace: workspace,
          version_number: 1,
          config: Schema::DEFAULT_CONFIG,
          config_digest: Schema.digest(Schema::DEFAULT_CONFIG),
          published_by_user: actor
        )
        configuration.update!(current_published_version: version)
        configuration.publication_events.create!(
          coach_workspace: workspace,
          workspace_brand_version: version,
          actor_user: actor,
          event_type: "publish",
          idempotency_key: "provision-workspace-#{workspace.id}-brand-v1",
          request_fingerprint: Digest::SHA256.hexdigest("provision-workspace-#{workspace.id}-brand-v1")
        )
        configuration
      end
    rescue ActiveRecord::RecordNotUnique
      workspace.reload.workspace_brand_configuration || raise
    end

    private

    attr_reader :workspace, :actor
  end
end
