# frozen_string_literal: true

require "digest"
require "json"

module CohortReleases
  module Contract
    V1_SCHEMA = "cohort_release_manifest_v1"
    V2_SCHEMA = "cohort_release_manifest_v2"
    CURRENT_SCHEMA = V2_SCHEMA
    MANIFEST_SCHEMA = CURRENT_SCHEMA
    SUPPORTED_SCHEMAS = [ V1_SCHEMA, V2_SCHEMA ].freeze
    TOOL_REGISTRY_VERSION = 1

    def self.deep_freeze(value)
      case value
      when Hash
        value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
      when Array
        value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end

    # This is the brand participants saw before cohort releases carried explicit brand evidence.
    # Keep it literal so later edits to Branding::Schema::DEFAULT_CONFIG cannot rewrite v1 history.
    LEGACY_HOUSEHOLD_CFO_CONFIG_V1 = deep_freeze(
      {
        "schema_version" => 1,
        "product_name" => "Household CFO",
        "short_name" => "Household CFO",
        "organization_name" => "Household CFO Method",
        "participant_role_term" => "household CFO",
        "powered_by_name" => "VERA",
        "powered_by_placement" => "header",
        "tagline" => "Your household finance command center",
        "welcome_heading" => "Your household money, in one clear place",
        "welcome_description" => "Plan the month, understand what changed, and make confident decisions with your coach's guidance.",
        "logo_url" => nil,
        "favicon_url" => nil,
        "support" => {
          "label" => "Contact your coach",
          "email" => nil,
          "url" => nil
        },
        "colors" => {
          "background" => "#f7f2ea",
          "surface" => "#fffdf8",
          "surface_muted" => "#fbf7ef",
          "text" => "#1f2421",
          "text_muted" => "#706d66",
          "border" => "#e2d9cb",
          "primary" => "#7b4a58",
          "primary_hover" => "#633944",
          "primary_soft" => "#f1e2e3",
          "accent" => "#b97352",
          "on_primary" => "#ffffff",
          "focus" => "#7b4a58"
        },
        "typography" => {
          "display" => "cormorant_garamond",
          "body" => "montserrat"
        },
        "footer" => {
          "text" => "Household CFO provides educational guidance and is not a substitute for individualized legal, tax, investment, or accounting advice.",
          "privacy_url" => nil,
          "terms_url" => nil
        }
      }
    )

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

    def published_brand_snapshot(version:)
      canonicalize(
        "mode" => "published_version",
        "configuration_id" => version.workspace_brand_configuration_id,
        "version_id" => version.id,
        "version_number" => version.version_number,
        "config" => Branding::Schema.normalize(version.config),
        "config_digest" => version.config_digest
      )
    end

    def legacy_brand_snapshot
      canonicalize(
        "mode" => "legacy_household_cfo_builtin",
        "config" => LEGACY_HOUSEHOLD_CFO_CONFIG_V1,
        "config_digest" => Branding::Schema.digest(LEGACY_HOUSEHOLD_CFO_CONFIG_V1)
      )
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

    def bundle(schema:, cohort:, persona_snapshot:, experience_snapshot:, tool_registry_snapshot: self.tool_registry_snapshot,
      brand_snapshot: nil)
      case schema
      when V1_SCHEMA
        bundle_v1(
          cohort: cohort,
          persona_snapshot: persona_snapshot,
          experience_snapshot: experience_snapshot,
          tool_registry_snapshot: tool_registry_snapshot
        )
      when V2_SCHEMA
        bundle_v2(
          cohort: cohort,
          persona_snapshot: persona_snapshot,
          experience_snapshot: experience_snapshot,
          brand_snapshot: brand_snapshot || raise(ArgumentError, "brand_snapshot is required for v2"),
          tool_registry_snapshot: tool_registry_snapshot
        )
      else
        raise ArgumentError, "unsupported cohort release schema"
      end
    end

    def bundle_v1(cohort:, persona_snapshot:, experience_snapshot:, tool_registry_snapshot: self.tool_registry_snapshot)
      canonicalize(
        "schema" => V1_SCHEMA,
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "persona" => component(persona_snapshot),
        "experience" => component(experience_snapshot),
        "tool_registry" => {
          "version" => TOOL_REGISTRY_VERSION,
          "snapshot" => tool_registry_snapshot,
          "snapshot_digest" => digest(tool_registry_snapshot)
        }
      )
    end

    def bundle_v2(cohort:, persona_snapshot:, experience_snapshot:, brand_snapshot:,
      tool_registry_snapshot: self.tool_registry_snapshot)
      canonicalize(
        "schema" => V2_SCHEMA,
        "cohort_id" => cohort.id,
        "coach_workspace_id" => cohort.coach_workspace_id,
        "brand" => component(brand_snapshot),
        "persona" => component(persona_snapshot),
        "experience" => component(experience_snapshot),
        "tool_registry" => {
          "version" => TOOL_REGISTRY_VERSION,
          "snapshot" => tool_registry_snapshot,
          "snapshot_digest" => digest(tool_registry_snapshot)
        }
      )
    end

    def manifest(schema:, **attributes)
      case schema
      when V1_SCHEMA then manifest_v1(**attributes)
      when V2_SCHEMA then manifest_v2(**attributes)
      else raise ArgumentError, "unsupported cohort release schema"
      end
    end

    def manifest_v1(**attributes)
      canonical_manifest(V1_SCHEMA, **attributes)
    end

    def manifest_v2(**attributes)
      canonical_manifest(V2_SCHEMA, **attributes)
    end

    def component(snapshot)
      {
        "mode" => snapshot.fetch("mode"),
        "snapshot" => snapshot,
        "snapshot_digest" => digest(snapshot)
      }
    end
    private_class_method :component

    def canonical_manifest(schema, release_number:, publication_source:, event_type:, released_by_user_id:,
      actor_role_snapshot:, source_release_id:, request_key:, request_fingerprint:, released_at:, bundle_digest:)
      canonicalize(
        "schema" => schema,
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
    private_class_method :canonical_manifest
  end
end
