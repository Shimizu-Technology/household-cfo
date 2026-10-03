# frozen_string_literal: true

module CohortReleases
  class CandidateBuilder
    Candidate = Data.define(
      :cohort,
      :assignment,
      :persona,
      :persona_version,
      :experience_configuration,
      :experience_version,
      :brand_version,
      :persona_snapshot,
      :experience_snapshot,
      :brand_snapshot,
      :tool_registry_snapshot,
      :bundle,
      :bundle_digest,
      :blockers,
      :warnings,
      :ambiguous_participant_count
    )

    def initialize(cohort:, strict:)
      @cohort = cohort
      @strict = strict
    end

    def call
      assignment, persona, persona_version, persona_snapshot, persona_blockers, persona_warnings = persona_component
      configuration, experience_version, experience_snapshot, experience_blockers, experience_warnings = experience_component
      brand_version, brand_snapshot, brand_blockers, brand_warnings = brand_component
      registry = Contract.tool_registry_snapshot
      release_bundle = Contract.bundle(
        schema: Contract::CURRENT_SCHEMA,
        cohort: cohort,
        persona_snapshot: persona_snapshot,
        experience_snapshot: experience_snapshot,
        brand_snapshot: brand_snapshot,
        tool_registry_snapshot: registry
      )

      ambiguous_count = ambiguous_participant_count
      ambiguity_message = "#{ambiguous_count} participant(s) have conflicting active cohort configurations."
      Candidate.new(
        cohort: cohort,
        assignment: assignment,
        persona: persona,
        persona_version: persona_version,
        experience_configuration: configuration,
        experience_version: experience_version,
        brand_version: brand_version,
        persona_snapshot: persona_snapshot,
        experience_snapshot: experience_snapshot,
        brand_snapshot: brand_snapshot,
        tool_registry_snapshot: registry,
        bundle: release_bundle,
        bundle_digest: Contract.digest(release_bundle),
        blockers: persona_blockers + experience_blockers + brand_blockers +
          (strict && ambiguous_count.positive? ? [ ambiguity_message ] : []),
        warnings: persona_warnings + experience_warnings + brand_warnings +
          (!strict && ambiguous_count.positive? ? [ ambiguity_message ] : []),
        ambiguous_participant_count: ambiguous_count
      )
    end

    private

    attr_reader :cohort, :strict

    def persona_component
      assignment = cohort.cohort_persona_assignment
      return fallback_persona(nil, "No published persona is selected for this cohort.") unless assignment

      persona = assignment.coach_persona
      version = assignment.coach_persona_version
      runtime_valid = persona&.current_published_version_id == version&.id && persona&.archived_at.nil?
      begin
        snapshot = Contract.persona_snapshot(version: version) if runtime_valid
      rescue Mia::PersonaSchema::InvalidConfiguration, ArgumentError, KeyError
        runtime_valid = false
      end

      return fallback_persona(assignment, "The selected persona is not valid for participant runtime.") unless runtime_valid

      blockers = []
      if strict && !(version.sealed? && version.release_gate_version == "gate_v2" && version.release_evidence_valid?)
        blockers << "Publish the selected persona through the governed release checks before sealing a cohort release."
      end
      [ assignment, persona, version, snapshot, blockers, [] ]
    end

    def fallback_persona(assignment, message)
      blocker = strict ? [ message ] : []
      warning = strict ? [] : [ message ]
      [ assignment, nil, nil, Contract.neutral_persona_snapshot, blocker, warning ]
    end

    def experience_component
      configuration = cohort.cohort_experience_configuration
      raise ArgumentError, "Cohort experience configuration is missing" unless configuration

      version = configuration.current_published_version
      valid = version && version.cohort_experience_configuration_id == configuration.id &&
        CohortExperience::Schema.errors(version.config).empty? &&
        version.config_digest == CohortExperience::Schema.digest(version.config)
      if valid
        return [ configuration, version, Contract.experience_snapshot(configuration: configuration, version: version), [], [] ]
      end

      message = "Publish participant tools before sealing a cohort release."
      [
        configuration,
        nil,
        Contract.experience_snapshot(configuration: configuration),
        strict ? [ message ] : [],
        strict ? [] : [ "Participant tools currently use the safe default." ]
      ]
    end

    def brand_component
      configuration = cohort.coach_workspace.workspace_brand_configuration
      version = configuration&.current_published_version
      valid = version && version.coach_workspace_id == cohort.coach_workspace_id &&
        version.workspace_brand_configuration_id == configuration.id &&
        Branding::Schema.errors(version.config).empty? &&
        version.config_digest == Branding::Schema.digest(version.config)
      if valid
        return [ version, Contract.published_brand_snapshot(version: version), [], [] ]
      end

      message = "Publish the workspace brand before sealing a cohort release."
      [
        nil,
        Contract.legacy_brand_snapshot,
        strict ? [ message ] : [],
        strict ? [] : [ "Branding currently uses the historical Household CFO identity." ]
      ]
    end

    def ambiguous_participant_count
      participant_ids = cohort.cohort_memberships.where(role: "participant").select(:user_id)
      return 0 unless participant_ids.exists?

      rows = CohortMembership
        .joins(:cohort)
        .left_joins(cohort: %i[cohort_persona_assignment cohort_experience_configuration])
        .where(user_id: participant_ids, role: "participant", cohorts: { status: Mia::PersonaResolver::ASSIGNABLE_COHORT_STATUSES })
        .pluck(
          :user_id,
          "cohort_persona_assignments.coach_persona_id",
          "cohort_persona_assignments.coach_persona_version_id",
          "cohort_experience_configurations.current_published_version_id"
        )
      rows.group_by(&:first).count do |_user_id, entries|
        entries.map { |entry| entry.drop(1) }.uniq.length > 1
      end
    end
  end
end
