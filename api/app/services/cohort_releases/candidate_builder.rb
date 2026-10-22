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
      :ambiguous_participant_count,
      # Which part each blocker belongs to, so readiness never depends on wording.
      :blockers_by_component
    )

    def initialize(cohort:, strict:)
      @cohort = cohort
      @strict = strict
    end

    def call
      assignment, persona, persona_version, persona_snapshot, persona_blockers, persona_warnings = persona_component
      configuration, experience_version, experience_snapshot, experience_blockers, experience_warnings = experience_component
      brand_version, brand_snapshot, brand_blockers, brand_warnings = brand_component
      registry = Contract.tool_registry_snapshot(
        version: ToolContracts.version_for_experience(experience_snapshot.fetch("config"))
      )
      release_bundle = Contract.bundle(
        schema: Contract::CURRENT_SCHEMA,
        cohort: cohort,
        persona_snapshot: persona_snapshot,
        experience_snapshot: experience_snapshot,
        brand_snapshot: brand_snapshot,
        tool_registry_snapshot: registry
      )

      conflicts = ParticipantConflicts.new(cohort: cohort)
      ambiguous_count = conflicts.entries.length
      ambiguity_messages = conflicts.messages
      tool_blockers = tool_contract_blockers(registry)
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
        blockers: persona_blockers + experience_blockers + brand_blockers + tool_blockers +
          (strict && ambiguous_count.positive? ? ambiguity_messages : []),
        warnings: persona_warnings + experience_warnings + brand_warnings +
          (!strict && ambiguous_count.positive? ? ambiguity_messages : []),
        ambiguous_participant_count: ambiguous_count,
        blockers_by_component: { persona: persona_blockers, experience: experience_blockers, brand: brand_blockers, tools: tool_blockers }
      )
    end

    private

    attr_reader :cohort, :strict

    def tool_contract_blockers(registry)
      compatible = ToolContracts.runtime_compatible?(registry, version: registry.fetch("schema_version"),
        runtime_snapshot: Contract.runtime_tool_registry_snapshot)
      compatible ? [] : [ "The selected tool contract requires supported operation versions and module definitions." ]
    rescue ArgumentError, NameError
      [ "The selected tool contract could not validate its registered operation handlers." ]
    end

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
        blockers << "Publish Mia’s voice, with its safety checks, before preparing a version for this group."
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

      message = "Publish participant tools before preparing a version for this group."
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

      message = "Publish the program’s look before preparing a version for this group."
      [
        nil,
        Contract.legacy_brand_snapshot,
        strict ? [ message ] : [],
        strict ? [] : [ "Branding currently uses the historical Household CFO identity." ]
      ]
    end
  end
end
