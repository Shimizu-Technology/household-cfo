# frozen_string_literal: true

module Branding
  class LogoAsset
    PURPOSE = "workspace-brand-logo-v1"
    PATH = "/api/public/brand_logos/"
    TOKEN = /\A[A-Za-z0-9_=-]+\z/

    def self.verifier
      ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key(PURPOSE),
        digest: "SHA256", serializer: JSON, url_safe: true
      )
    end

    def self.token(workspace_id:, asset_id:)
      verifier.generate({ "workspace_id" => workspace_id, "asset_id" => asset_id }, purpose: PURPOSE)
    end

    def self.key(workspace_id:, asset_id:)
      S3Service.namespaced_key("branding", "workspaces", workspace_id.to_s, "logos", "#{asset_id}.png")
    end

    def self.key_from_token(token)
      return unless token.is_a?(String) && token.length <= 1024 && TOKEN.match?(token)

      payload = verifier.verified(token, purpose: PURPOSE)
      return unless payload.is_a?(Hash) && payload["workspace_id"].is_a?(Integer) && payload["workspace_id"].positive?
      return unless payload["asset_id"].is_a?(String) && payload["asset_id"].match?(/\A[0-9a-f-]{36}\z/)

      key(workspace_id: payload["workspace_id"], asset_id: payload["asset_id"])
    end

    # Local QA uses separate HTTP API/web ports. Production assets always use
    # HTTPS; no general HTTP authoring exception is introduced.
    def self.local_url?(uri)
      uri.is_a?(URI::HTTP) && !uri.is_a?(URI::HTTPS) &&
        %w[localhost 127.0.0.1 [::1]].include?(uri.host) &&
        uri.path.start_with?(PATH) && TOKEN.match?(uri.path.delete_prefix(PATH)) && uri.query.nil?
    end
  end
end
