# frozen_string_literal: true

module CohortReleases
  class RuntimeIntegrityCache
    CACHE_SCHEMA = 2
    STORE = ActiveSupport::Cache::MemoryStore.new(size: 2.megabytes)

    class << self
      def valid_runtime?(release)
        STORE.fetch(cache_key(release)) do
          report = release.integrity_report
          report.fetch(:valid) && report.fetch(:runtime_compatible)
        end
      rescue StandardError => error
        Rails.logger.error(
          "[CohortReleases::RuntimeIntegrityCache] fail closed release_id=#{release&.id} error=#{error.class}"
        )
        false
      end

      def clear!
        STORE.clear
      end

      private

      def cache_key(release)
        [
          "cohort-release-runtime-integrity",
          CACHE_SCHEMA,
          release.id,
          release.bundle_digest,
          release.manifest_digest,
          release.manifest_schema,
          Contract::CURRENT_SCHEMA,
          Contract::SUPPORTED_SCHEMAS.join(","),
          Contract::TOOL_REGISTRY_VERSION,
          Contract.digest(Contract.tool_registry_snapshot)
        ]
      end
    end
  end
end
