# frozen_string_literal: true

module CohortExperience
  class EffectiveCapabilitiesResolver
    class << self
      def for_release(release:, cohort_membership:)
        snapshot = release.experience_snapshot.deep_stringify_keys
        raise ArgumentError, "release experience snapshot is invalid" unless snapshot["configuration_id"] ==
          release.cohort_experience_configuration_id

        raise ArgumentError, "release experience configuration is invalid" if Schema.errors(snapshot.fetch("config")).any?
        unless CohortReleases::ToolContracts.supported_snapshot?(release.tool_registry_snapshot, version: release.tool_registry_version) &&
            CohortReleases::ToolContracts.supports_experience?(release.tool_registry_snapshot, snapshot.fetch("config"))
          raise ArgumentError, "release tool contract does not support this experience"
        end

        config = CohortExperience::Schema.normalize(snapshot.fetch("config"))
        source = snapshot.fetch("mode") == "published_version" ? "cohort_release" : "safe_default_release"
        payload_for(
          config: config,
          source: source,
          cohort_membership: cohort_membership,
          version: release.cohort_experience_version,
          release: release
        )
      end

      def safe_default_payload(cohort_membership:, standalone: false)
        config = standalone ? Schema::LEGACY_CONFIG : Schema::DEFAULT_CONFIG
        payload_for(
          config: config,
          source: standalone ? "standalone_default" : "safe_default",
          cohort_membership: cohort_membership,
          version: nil,
          release: nil
        )
      end

      def payload_for(config:, source:, cohort_membership:, version:, release: nil)
        enabled = config.fetch("optional_modules")
        definitions = release ? release.tool_registry_snapshot.fetch("modules").map(&:deep_symbolize_keys) : ModuleRegistry::MODULES
        payload = {
          schema_version: config.fetch("schema_version"),
          source: source,
          cohort_id: cohort_membership&.cohort_id,
          cohort_release: release && { id: release.id, number: release.release_number },
          experience_version: version && { id: version.id, number: version.version_number },
          modules: definitions.map do |item|
            module_enabled = item.fetch(:core) || enabled.fetch(item.fetch(:id), false)
            item.merge(enabled: module_enabled).tap do |payload|
              payload.delete(:unavailable_message) if module_enabled
            end
          end
        }
        payload[:experience_mode] = config.fetch("experience_mode") if config.fetch("schema_version") == 2
        payload
      end
    end

    def initialize(cohort_membership:)
      @cohort_membership = cohort_membership
    end

    def call
      config, source, version = effective_config
      self.class.payload_for(
        config: config,
        source: source,
        cohort_membership: cohort_membership,
        version: version
      )
    rescue StandardError => error
      Rails.logger.error("[CohortExperience] safe default error=#{error.class} cohort_id=#{cohort_membership&.cohort_id}")
      payload_for_safe_default
    end

    private

    attr_reader :cohort_membership

    def effective_config
      return [ Schema::LEGACY_CONFIG, "standalone_default", nil ] unless cohort_membership

      configuration = cohort_membership.cohort.cohort_experience_configuration
      version = configuration&.current_published_version
      return [ Schema::DEFAULT_CONFIG, "safe_default", nil ] unless version
      return [ Schema::DEFAULT_CONFIG, "safe_default", nil ] unless version.cohort_experience_configuration_id == configuration.id
      return [ Schema::DEFAULT_CONFIG, "safe_default", nil ] if Schema.errors(version.config).any?
      return [ Schema::DEFAULT_CONFIG, "safe_default", nil ] unless version.config_digest == Schema.digest(version.config)

      [ Schema.normalize(version.config), "published_cohort", version ]
    end

    def payload_for_safe_default
      self.class.safe_default_payload(cohort_membership: cohort_membership)
    end
  end
end
