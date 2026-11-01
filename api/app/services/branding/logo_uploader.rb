# frozen_string_literal: true

module Branding
  class LogoUploader
    class Conflict < StandardError; end
    class Unavailable < StandardError; end

    def initialize(configuration:, actor:, base_url:)
      @configuration = configuration
      @actor = actor
      @base_url = base_url
    end

    def call(file:, expected_draft_revision:)
      with_draft(expected_draft_revision) { } # Reject stale or revoked requests before storing bytes.
      bytes = LogoImage.read!(file)
      asset_id = SecureRandom.uuid
      key = LogoAsset.key(workspace_id: @configuration.coach_workspace_id, asset_id: asset_id)
      begin
        raise Unavailable unless S3Service.upload(key, bytes, content_type: "image/png")
        token = LogoAsset.token(workspace_id: @configuration.coach_workspace_id, asset_id: asset_id)
        with_draft(expected_draft_revision) do |actor|
          @configuration.update!(
            draft_config: @configuration.draft_config.merge("logo_url" => "#{@base_url}#{LogoAsset::PATH}#{token}"),
            last_edited_by_user: actor
          )
        end
      rescue StandardError
        # Only this attempt's random key is eligible for cleanup. Published and
        # superseded assets are retained for sealed releases and rollback.
        begin
          S3Service.delete(key)
        rescue S3Service::MissingConfigurationError, Aws::Errors::ServiceError, Seahorse::Client::NetworkingError
          Rails.logger.warn("[Branding] Logo upload cleanup unavailable")
        end
        raise
      end
      @configuration
    rescue S3Service::MissingConfigurationError, Aws::Errors::ServiceError, Seahorse::Client::NetworkingError
      raise Unavailable
    end

    private

    def with_draft(revision)
      CoachWorkspaces::MutationAuthority.new(workspace: @configuration.coach_workspace, actor: @actor, permissions: :edit).call do |actor|
        @configuration.lock!
        unless Integer(revision, exception: false) == @configuration.draft_revision
          raise Conflict, "This appearance changed in another session. Reload before uploading your logo."
        end
        yield actor
      end
    end
  end
end
