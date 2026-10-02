# frozen_string_literal: true

require "digest"
require "json"

module CohortReleases
  module Contract
    MANIFEST_SCHEMA = "cohort_release_manifest_v1"
    TOOL_REGISTRY_VERSION = 1

    module_function

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(value)).b)
    end

    def canonicalize(value)
      case value
      when Hash
        value.to_h
          .each_with_object({}) { |(key, entry), result| result[key.to_s] = canonicalize(entry) }
          .sort_by(&:first)
          .to_h
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end

    def persona_snapshot(version: nil)
      return neutral_persona_snapshot unless version

      Mia::PersonaRuntimeCompatibility.call(version)
      canonicalize(
        "mode" => "published_version",
        "persona_id" => version.coach_persona_id,
        "version_id" => version.id,
        "version_number" => version.version_number,
        "config_digest" => version.config_digest,
        "content_manifest_digest" => version.content_manifest_digest,
        "phrase_manifest_digest" => version.phrase_manifest_digest,
        "release_gate_version" => version.release_gate_version,
        "release_evidence_schema" => version.release_evidence_schema,
        "release_evidence_digest" => version.release_evidence_digest
      )
    end

    def neutral_persona_snapshot
      persona = Mia::Persona.neutral
      canonicalize(
        "mode" => "neutral_builtin",
        "builtin_id" => persona.id,
        "data" => persona.data
      )
    end

    def experience_snapshot(configuration:, version: nil)
      if version
        canonicalize(
          "mode" => "published_version",
          "configuration_id" => configuration.id,
          "version_id" => version.id,
          "version_number" => version.version_number,
          "config" => CohortExperience::Schema.normalize(version.config),
          "config_digest" => version.config_digest
        )
      else
        canonicalize(
          "mode" => "safe_default",
          "configuration_id" => configuration.id,
          "config" => CohortExperience::Schema::DEFAULT_CONFIG
        )
      end
    end

    def tool_registry_snapshot
      canonicalize(
        "schema_version" => TOOL_REGISTRY_VERSION,
        "modules" => CohortExperience::ModuleRegistry::MODULES.map { |entry| entry.deep_stringify_keys },
        "operations" => HouseholdFinance::Operations::Registry.operations.sort_by { |key, _operation| key }.map do |key, operation|
          { "key" => key, "version" => operation::VERSION }
        end
      )
    end

    def bundle(cohort:, persona_snapshot:, experience_snapshot:, tool_registry_snapshot: self.tool_registry_snapshot)
      canonicalize(
        "schema" => MANIFEST_SCHEMA,
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "persona" => {
          "mode" => persona_snapshot.fetch("mode"),
          "snapshot" => persona_snapshot,
          "snapshot_digest" => digest(persona_snapshot)
        },
        "experience" => {
          "mode" => experience_snapshot.fetch("mode"),
          "snapshot" => experience_snapshot,
          "snapshot_digest" => digest(experience_snapshot)
        },
        "tool_registry" => {
          "version" => TOOL_REGISTRY_VERSION,
          "snapshot" => tool_registry_snapshot,
          "snapshot_digest" => digest(tool_registry_snapshot)
        }
      )
    end

    def manifest(release_number:, publication_source:, event_type:, released_by_user_id:, actor_role_snapshot:, source_release_id:,
      request_key:, request_fingerprint:, released_at:, bundle_digest:)
      canonicalize(
        "schema" => MANIFEST_SCHEMA,
        "release_number" => release_number,
        "publication_source" => publication_source,
        "event_type" => event_type,
        "released_by_user_id" => released_by_user_id,
        "actor_role_snapshot" => actor_role_snapshot,
        "source_release_id" => source_release_id,
        "request_key" => request_key,
        "request_fingerprint" => request_fingerprint,
        "released_at" => released_at.utc.iso8601(6),
        "bundle_digest" => bundle_digest
      )
    end
  end
end
