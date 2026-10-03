# frozen_string_literal: true

module Branding
  class RuntimeResolver
    class << self
      def for_release(release)
        if release.manifest_schema == CohortReleases::Contract::V1_SCHEMA
          return legacy_default(source: "cohort_release_v1")
        end

        snapshot = release.brand_snapshot
        runtime_payload(
          snapshot.fetch("config"),
          source: "cohort_release_v2",
          mode: snapshot.fetch("mode"),
          version_id: release.workspace_brand_version_id,
          digest: snapshot.fetch("config_digest"),
          available: true
        )
      end

      def for_membership(membership)
        configuration = membership&.cohort&.coach_workspace&.workspace_brand_configuration
        for_configuration(configuration)
      end

      def for_workspace(workspace)
        for_configuration(workspace&.workspace_brand_configuration)
      end

      def for_configuration(configuration)
        return legacy_default(source: "legacy_household_cfo_default") unless configuration

        version = configuration&.current_published_version
        return safe_default unless valid_version?(version, configuration)

        runtime_payload(
          version.config,
          source: "published_workspace_brand",
          mode: "published_version",
          version_id: version.id,
          digest: version.config_digest,
          available: true
        )
      end
      private :for_configuration

      def legacy_default(source: "legacy_household_cfo_default")
        config = CohortReleases::Contract::LEGACY_HOUSEHOLD_CFO_CONFIG_V1
        runtime_payload(
          config,
          source: source,
          mode: "legacy_household_cfo_builtin",
          version_id: nil,
          digest: Schema.digest(config),
          available: true
        )
      end

      def safe_default
        runtime_payload(
          Schema::SAFE_DEFAULT_CONFIG,
          source: "safe_default",
          mode: "safe_default",
          version_id: nil,
          digest: Schema.digest(Schema::SAFE_DEFAULT_CONFIG),
          available: false
        )
      end

      private

      def valid_version?(version, configuration)
        version && version.workspace_brand_configuration_id == configuration.id &&
          version.coach_workspace_id == configuration.coach_workspace_id &&
          Schema.errors(version.config).empty? && version.config_digest == Schema.digest(version.config)
      end

      def runtime_payload(config, source:, mode:, version_id:, digest:, available:)
        {
          source: source,
          mode: mode,
          version_id: version_id,
          digest: digest,
          available: available,
          config: Schema.normalize(config)
        }
      end
    end
  end
end
