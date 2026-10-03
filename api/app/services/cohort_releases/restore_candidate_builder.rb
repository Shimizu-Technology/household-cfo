# frozen_string_literal: true

module CohortReleases
  class RestoreCandidateBuilder
    def initialize(cohort:, source_release:)
      @cohort = cohort
      @source_release = source_release
    end

    def call
      brand_version, brand_snapshot = brand_component
      release_bundle = Contract.bundle(
        schema: Contract::CURRENT_SCHEMA,
        cohort: cohort,
        persona_snapshot: source_release.persona_snapshot,
        experience_snapshot: source_release.experience_snapshot,
        brand_snapshot: brand_snapshot,
        tool_registry_snapshot: source_release.tool_registry_snapshot
      )

      CandidateBuilder::Candidate.new(
        cohort: cohort,
        assignment: nil,
        persona: source_release.coach_persona,
        persona_version: source_release.coach_persona_version,
        experience_configuration: source_release.cohort_experience_configuration,
        experience_version: source_release.cohort_experience_version,
        brand_version: brand_version,
        persona_snapshot: source_release.persona_snapshot.deep_dup,
        experience_snapshot: source_release.experience_snapshot.deep_dup,
        brand_snapshot: brand_snapshot.deep_dup,
        tool_registry_snapshot: source_release.tool_registry_snapshot.deep_dup,
        bundle: release_bundle,
        bundle_digest: Contract.digest(release_bundle),
        blockers: [],
        warnings: [],
        ambiguous_participant_count: 0
      )
    end

    private

    attr_reader :cohort, :source_release

    def brand_component
      if source_release.manifest_schema == Contract::V2_SCHEMA
        [ source_release.workspace_brand_version, source_release.brand_snapshot ]
      else
        [ nil, Contract.legacy_brand_snapshot ]
      end
    end
  end
end
