# frozen_string_literal: true

module Branding
  class PublicResolver
    Result = Data.define(:config, :source, :available, :workspace, :version, :primary_domain)

    def initialize(hostname:)
      @hostname = Hostname.normalize(hostname)
    end

    def call
      return unavailable unless hostname
      return legacy_default if Hostname::LOCAL.include?(hostname) || Hostname.legacy?(hostname)

      domain = CoachWorkspaceDomain.active.includes(
        coach_workspace: { workspace_brand_configuration: :current_published_version }
      ).find_by(hostname: hostname)
      return unavailable unless domain

      configuration = domain.coach_workspace.workspace_brand_configuration
      version = configuration&.current_published_version
      return unavailable unless version && version.config_digest == Schema.digest(version.config)

      Result.new(
        config: version.config,
        source: "published_workspace_brand",
        available: true,
        workspace: domain.coach_workspace,
        version: version,
        primary_domain: domain.coach_workspace.coach_workspace_domains.active.find_by(is_primary: true)&.hostname || domain.hostname
      )
    rescue ActiveRecord::StatementInvalid, JSON::ParserError, TypeError
      unavailable
    end

    private

    attr_reader :hostname

    def legacy_default
      Result.new(
        config: Schema::DEFAULT_CONFIG,
        source: "legacy_household_cfo_default",
        available: true,
        workspace: nil,
        version: nil,
        primary_domain: hostname
      )
    end

    def unavailable
      Result.new(
        config: Schema::SAFE_DEFAULT_CONFIG,
        source: "safe_default",
        available: false,
        workspace: nil,
        version: nil,
        primary_domain: nil
      )
    end
  end
end
