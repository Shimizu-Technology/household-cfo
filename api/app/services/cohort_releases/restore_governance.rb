# frozen_string_literal: true

module CohortReleases
  class RestoreGovernance
    def initialize(cohort:, source_release:)
      @cohort = cohort
      @source_release = source_release
    end

    def call
      persona_blockers + experience_blockers + ambiguity_blockers
    end

    private

    attr_reader :cohort, :source_release

    def persona_blockers
      persona = source_release.coach_persona
      version = source_release.coach_persona_version
      governed = source_release.persona_mode == "published_version" && persona && version &&
        persona.archived_at.nil? && version.sealed? && version.release_gate_version == "gate_v2" &&
        version.release_evidence_valid?
      governed ? [] : [ "Restore a release with a governed, active coach persona." ]
    end

    def experience_blockers
      version = source_release.cohort_experience_version
      valid = source_release.experience_mode == "published_version" && version &&
        CohortExperience::Schema.errors(version.config).empty? &&
        version.config_digest == CohortExperience::Schema.digest(version.config)
      valid ? [] : [ "Restore a release with published participant tools." ]
    end

    def ambiguity_blockers
      count = CandidateBuilder.new(cohort: cohort, strict: false).call.ambiguous_participant_count
      count.positive? ? [ "#{count} participant(s) have conflicting active cohort configurations." ] : []
    end
  end
end
