# frozen_string_literal: true

module CohortExperience
  class EffectiveCapabilitiesResolver
    def initialize(cohort_membership:)
      @cohort_membership = cohort_membership
    end

    def call
      config, source, version = effective_config
      enabled = config.fetch("optional_modules")
      {
        schema_version: 1,
        source: source,
        cohort_id: cohort_membership&.cohort_id,
        experience_version: version && { id: version.id, number: version.version_number },
        modules: ModuleRegistry::MODULES.map do |item|
          module_enabled = item.fetch(:core) || enabled.fetch(item.fetch(:id), false)
          item.merge(enabled: module_enabled).tap do |payload|
            payload.delete(:unavailable_message) if module_enabled
          end
        end
      }
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
      {
        schema_version: 1,
        source: "safe_default",
        cohort_id: cohort_membership&.cohort_id,
        experience_version: nil,
        modules: ModuleRegistry::MODULES.map do |item|
          enabled = item.fetch(:core)
          item.merge(enabled: enabled).tap { |payload| payload.delete(:unavailable_message) if enabled }
        end
      }
    end
  end
end
