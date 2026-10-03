# frozen_string_literal: true

module CohortReleases
  class SemanticParity
    def initialize(candidate:, release:)
      @candidate = candidate
      @release = release
    end

    def equivalent?
      return secure_match?(candidate.bundle_digest, release.bundle_digest) if release.manifest_schema == Contract::V2_SCHEMA
      return false unless release.manifest_schema == Contract::V1_SCHEMA

      release.persona_snapshot == candidate.persona_snapshot &&
        release.experience_snapshot == candidate.experience_snapshot &&
        release.tool_registry_snapshot == candidate.tool_registry_snapshot &&
        candidate.brand_snapshot.fetch("config") == Contract::LEGACY_HOUSEHOLD_CFO_CONFIG_V1
    rescue KeyError
      false
    end

    private

    attr_reader :candidate, :release

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
