# frozen_string_literal: true

module CohortReleases
  class Integrity
    UNSET = Object.new.freeze

    def initialize(release, current_tool_registry_snapshot: nil,
      current_persona_snapshot: UNSET, persona_evidence_valid: UNSET)
      @release = release
      @current_tool_registry_snapshot = current_tool_registry_snapshot
      @current_persona_snapshot = current_persona_snapshot
      @persona_evidence_valid = persona_evidence_valid
    end

    def call
      errors = []
      unless Contract::SUPPORTED_SCHEMAS.include?(release.manifest_schema)
        errors << "Release manifest schema is unsupported"
        return report(errors)
      end

      compare_digest(errors, release.persona_snapshot, release.persona_snapshot_digest, "Persona snapshot")
      compare_digest(errors, release.experience_snapshot, release.experience_snapshot_digest, "Experience snapshot")
      compare_digest(errors, release.tool_registry_snapshot, release.tool_registry_digest, "Tool registry snapshot")
      compare_digest(errors, release.bundle, release.bundle_digest, "Release bundle")
      compare_digest(errors, release.manifest, release.manifest_digest, "Release manifest")
      verify_brand(errors)
      errors << "Release bundle fields do not match the sealed record" unless release.bundle == expected_bundle
      errors << "Release manifest fields do not match the sealed record" unless release.manifest == expected_manifest
      verify_persona(errors)
      verify_experience(errors)
      report(errors)
    rescue StandardError => error
      { valid: false, errors: [ "Release integrity check failed: #{error.class}" ], runtime_compatible: false }
    end

    private

    attr_reader :release, :current_tool_registry_snapshot, :current_persona_snapshot,
      :persona_evidence_valid

    def report(errors)
      {
        valid: errors.empty?,
        errors: errors,
        runtime_compatible: errors.empty? && current_runtime_compatible?
      }
    end

    def compare_digest(errors, payload, expected, label)
      errors << "#{label} digest does not match" unless secure_match?(Contract.digest(payload), expected)
    end

    def expected_bundle
      Contract.bundle(
        schema: release.manifest_schema,
        cohort: release.cohort,
        persona_snapshot: release.persona_snapshot,
        experience_snapshot: release.experience_snapshot,
        brand_snapshot: release.brand_snapshot,
        tool_registry_snapshot: release.tool_registry_snapshot
      )
    end

    def expected_manifest
      Contract.manifest(
        schema: release.manifest_schema,
        release_number: release.release_number,
        publication_source: release.publication_source,
        event_type: release.event_type,
        released_by_user_id: release.released_by_user_id,
        actor_role_snapshot: release.actor_role_snapshot,
        source_release_id: release.source_release_id,
        request_key: release.request_key,
        request_fingerprint: release.request_fingerprint,
        released_at: release.released_at,
        bundle_digest: release.bundle_digest
      )
    end

    def verify_brand(errors)
      if release.manifest_schema == Contract::V1_SCHEMA
        unless release.brand_mode.nil? && release.workspace_brand_version_id.nil? &&
            release.brand_snapshot.nil? && release.brand_snapshot_digest.nil?
          errors << "V1 release contains unexpected brand evidence"
        end
        return
      end

      compare_digest(errors, release.brand_snapshot, release.brand_snapshot_digest, "Brand snapshot")
      snapshot = release.brand_snapshot
      if release.brand_mode == "published_version"
        version = release.workspace_brand_version
        linked = version && snapshot["mode"] == "published_version" &&
          snapshot["configuration_id"] == version.workspace_brand_configuration_id &&
          snapshot["version_id"] == version.id && snapshot["version_number"] == version.version_number &&
          snapshot["config"] == Branding::Schema.normalize(version.config) &&
          snapshot["config_digest"] == version.config_digest &&
          version.coach_workspace_id == release.coach_workspace_id &&
          Branding::Schema.errors(version.config).empty? &&
          version.config_digest == Branding::Schema.digest(version.config)
        errors << "Published brand snapshot does not match its immutable version" unless linked
      elsif release.brand_mode == "legacy_household_cfo_builtin"
        errors << "Historical Household CFO brand snapshot is malformed" unless snapshot == Contract.legacy_brand_snapshot
      else
        errors << "Brand snapshot mode is unsupported"
      end
    end

    def verify_persona(errors)
      if release.persona_mode == "published_version"
        version = release.coach_persona_version
        snapshot = release.persona_snapshot
        evidence_valid = persona_evidence_valid.equal?(UNSET) ? version&.release_evidence_valid? : persona_evidence_valid
        linked = version && snapshot["mode"] == "published_version" &&
          snapshot["persona_id"] == version.coach_persona_id && snapshot["version_id"] == version.id &&
          snapshot["version_number"] == version.version_number && snapshot["config_digest"] == version.config_digest &&
          snapshot["content_manifest_digest"] == version.content_manifest_digest &&
          snapshot["phrase_manifest_digest"] == version.phrase_manifest_digest &&
          snapshot["release_gate_version"] == version.release_gate_version &&
          snapshot["release_evidence_schema"] == version.release_evidence_schema &&
          snapshot["release_evidence_digest"] == version.release_evidence_digest && evidence_valid
        errors << "Published persona snapshot does not match its immutable version" unless linked
      elsif release.persona_snapshot.dig("mode") != "neutral_builtin" || release.persona_snapshot["builtin_id"].blank?
        errors << "Neutral persona snapshot is malformed"
      end
    end

    def verify_experience(errors)
      snapshot = release.experience_snapshot
      configuration = release.cohort_experience_configuration
      linked = snapshot["configuration_id"] == configuration&.id
      if release.experience_mode == "published_version"
        version = release.cohort_experience_version
        linked &&= version && snapshot["mode"] == "published_version" &&
          snapshot["version_id"] == version.id && snapshot["version_number"] == version.version_number &&
          snapshot["config_digest"] == version.config_digest &&
          CohortExperience::Schema.errors(version.config).empty? &&
          version.config_digest == CohortExperience::Schema.digest(version.config)
      else
        linked &&= snapshot["mode"] == "safe_default"
      end
      errors << "Participant-tools snapshot does not match its immutable version" unless linked
    end

    def current_runtime_compatible?
      return false unless release.tool_registry_version == Contract::TOOL_REGISTRY_VERSION
      registry_snapshot = current_tool_registry_snapshot || Contract.tool_registry_snapshot
      registry_digest = Contract.digest(registry_snapshot)
      return false unless release.tool_registry_digest == registry_digest

      persona_compatible = if release.persona_mode == "published_version"
        snapshot = if current_persona_snapshot.equal?(UNSET)
          Contract.persona_snapshot(version: release.coach_persona_version)
        else
          current_persona_snapshot
        end
        snapshot == release.persona_snapshot
      else
        Contract.neutral_persona_snapshot == release.persona_snapshot
      end
      experience_compatible = Contract.experience_snapshot(
        configuration: release.cohort_experience_configuration,
        version: release.cohort_experience_version
      ) == release.experience_snapshot
      persona_compatible && experience_compatible && brand_runtime_compatible?
    rescue Mia::PersonaSchema::InvalidConfiguration, ArgumentError, KeyError
      false
    end

    def brand_runtime_compatible?
      snapshot = if release.manifest_schema == Contract::V1_SCHEMA
        Contract.legacy_brand_snapshot
      else
        release.brand_snapshot
      end
      config = snapshot.fetch("config")
      Branding::Schema.errors(config).empty? &&
        snapshot.fetch("config_digest") == Branding::Schema.digest(config)
    end

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
