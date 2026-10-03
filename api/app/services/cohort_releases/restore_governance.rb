# frozen_string_literal: true

module CohortReleases
  class RestoreGovernance
    UNSET = Object.new.freeze

    def initialize(cohort:, source_release:, ambiguous_participant_count: nil, persona_governed: UNSET)
      @cohort = cohort
      @source_release = source_release
      @ambiguous_participant_count = ambiguous_participant_count
      @persona_governed = persona_governed
    end

    def call
      persona_blockers + experience_blockers + brand_blockers + ambiguity_blockers
    end

    private

    attr_reader :cohort, :source_release, :ambiguous_participant_count, :persona_governed

    def persona_blockers
      governed = persona_governed
      if governed.equal?(UNSET)
        persona = source_release.coach_persona
        version = source_release.coach_persona_version
        governed = source_release.persona_mode == "published_version" && persona && version &&
          persona.archived_at.nil? && version.sealed? && version.release_gate_version == "gate_v2" &&
          version.release_evidence_valid?
      end
      governed ? [] : [ "Restore a release with a governed, active coach persona." ]
    end

    def experience_blockers
      version = source_release.cohort_experience_version
      valid = source_release.experience_mode == "published_version" && version &&
        CohortExperience::Schema.errors(version.config).empty? &&
        version.config_digest == CohortExperience::Schema.digest(version.config)
      valid ? [] : [ "Restore a release with published participant tools." ]
    end

    def brand_blockers
      return [] if source_release.manifest_schema == Contract::V1_SCHEMA
      return [] if source_release.brand_mode == "legacy_household_cfo_builtin" &&
        source_release.brand_snapshot == Contract.legacy_brand_snapshot

      version = source_release.workspace_brand_version
      valid = source_release.brand_mode == "published_version" && version &&
        version.coach_workspace_id == source_release.coach_workspace_id &&
        Branding::Schema.errors(version.config).empty? &&
        version.config_digest == Branding::Schema.digest(version.config)
      valid ? [] : [ "Restore a release with valid historical brand evidence." ]
    end

    def ambiguity_blockers
      count = ambiguous_participant_count
      count = CandidateBuilder.new(cohort: cohort, strict: false).call.ambiguous_participant_count if count.nil?
      count.positive? ? [ "#{count} participant(s) have conflicting active cohort configurations." ] : []
    end
  end
end
