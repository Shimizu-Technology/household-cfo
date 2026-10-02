# frozen_string_literal: true

module CohortReleases
  class StudioSerializer
    HISTORY_LIMIT = 25
    RUNTIME_TRUTH = "Sealing or restoring a release record does not change the assistant or tools participants use.".freeze

    def initialize(cohort:, actor:)
      @cohort = cohort
      @actor = actor
    end

    def call
      candidate = CandidateBuilder.new(cohort: cohort, strict: true).call
      registry_snapshot = candidate.tool_registry_snapshot
      releases = release_history
      history_total_count = cohort.cohort_releases.count
      persona_assessment_cache = {}
      latest = releases.first
      authorized, actor_role = release_authority
      mutable = cohort.status.in?(CohortRelease::USER_RELEASE_COHORT_STATUSES)
      seal_needed = latest.nil? || !secure_match?(candidate.bundle_digest, latest.bundle_digest)
      blockers = candidate.blockers.dup
      operational_blockers = []
      operational_blockers << "Completed and archived cohorts are read-only." unless mutable
      operational_blockers << "This exact cohort release bundle is already sealed." unless seal_needed
      serialized_releases = releases.map do |release|
        assessment = persona_assessment(release, persona_assessment_cache)
        release_payload(
          release,
          authorized: authorized,
          mutable: mutable,
          latest: latest,
          ambiguous_participant_count: candidate.ambiguous_participant_count,
          registry_snapshot: registry_snapshot,
          current_persona_snapshot: assessment.fetch(:runtime_snapshot),
          persona_evidence_valid: assessment.fetch(:evidence_valid),
          persona_governed: assessment.fetch(:governed)
        )
      end

      {
        cohort: {
          id: cohort.id,
          name: cohort.name,
          status: cohort.status,
          participant_count: cohort.cohort_memberships.where(role: "participant").count
        },
        runtime_truth: {
          changes_participant_runtime: false,
          participant_runtime_changed: false,
          message: RUNTIME_TRUTH
        },
        permissions: {
          view: true,
          seal: authorized && mutable,
          restore: authorized && mutable,
          actor_role: actor_role,
          blockers: operational_blockers
        },
        readiness: {
          ready: blockers.empty?,
          seal_needed: seal_needed,
          blockers: blockers,
          warnings: candidate.warnings,
          ambiguous_participant_count: candidate.ambiguous_participant_count,
          checks: readiness_checks(candidate),
          candidate: candidate_payload(candidate, latest_release_id: latest&.id),
          latest_release_match: !seal_needed
        },
        history: {
          limit: HISTORY_LIMIT,
          total_count: history_total_count,
          truncated: history_total_count > releases.length
        },
        latest_release: serialized_releases.first,
        releases: serialized_releases
      }
    end

    def call_with_release(release)
      studio = call
      serialized_release = studio.fetch(:releases).find { |item| item.fetch(:id) == release.id }
      return [ studio, serialized_release ] if serialized_release

      candidate = CandidateBuilder.new(cohort: cohort, strict: false).call
      authorized, = release_authority
      assessment = persona_assessment(release, {})
      serialized_release = release_payload(
        release,
        authorized: authorized,
        mutable: cohort.status.in?(CohortRelease::USER_RELEASE_COHORT_STATUSES),
        latest: cohort.cohort_releases.order(release_number: :desc).first,
        ambiguous_participant_count: candidate.ambiguous_participant_count,
        registry_snapshot: candidate.tool_registry_snapshot,
        current_persona_snapshot: assessment.fetch(:runtime_snapshot),
        persona_evidence_valid: assessment.fetch(:evidence_valid),
        persona_governed: assessment.fetch(:governed)
      )
      [ studio, serialized_release ]
    end

    def release_payload(release, authorized:, mutable:, latest:, ambiguous_participant_count: nil,
      registry_snapshot: nil, current_persona_snapshot: Integrity::UNSET,
      persona_evidence_valid: Integrity::UNSET, persona_governed: RestoreGovernance::UNSET)
      integrity = Integrity.new(
        release,
        current_tool_registry_snapshot: registry_snapshot,
        current_persona_snapshot: current_persona_snapshot,
        persona_evidence_valid: persona_evidence_valid
      ).call
      restore_blockers = restore_blockers(
        release,
        latest: latest,
        integrity: integrity,
        ambiguous_participant_count: ambiguous_participant_count,
        persona_governed: persona_governed
      )
      {
        id: release.id,
        release_number: release.release_number,
        publication_source: release.publication_source,
        event_type: release.event_type,
        source_release_id: release.source_release_id,
        actor_user_id: release.released_by_user_id,
        actor_role_snapshot: release.actor_role_snapshot,
        actor: release.released_by_user && {
          id: release.released_by_user_id,
          full_name: release.released_by_user.full_name
        },
        persona_mode: release.persona_mode,
        coach_persona_id: release.coach_persona_id,
        coach_persona_version_id: release.coach_persona_version_id,
        experience_mode: release.experience_mode,
        cohort_experience_version_id: release.cohort_experience_version_id,
        tool_registry_version: release.tool_registry_version,
        tool_registry_digest: release.tool_registry_digest,
        bundle_digest: release.bundle_digest,
        manifest_digest: release.manifest_digest,
        released_at: release.released_at,
        integrity_valid: integrity.fetch(:valid),
        runtime_compatible: integrity.fetch(:runtime_compatible),
        restore_allowed: authorized && mutable && restore_blockers.empty?,
        restore_blockers: restore_blockers
      }
    end

    private

    attr_reader :cohort, :actor

    def release_history
      cohort.cohort_releases.order(release_number: :desc).limit(HISTORY_LIMIT).preload(
        :cohort,
        :released_by_user,
        :coach_persona,
        :cohort_experience_configuration,
        :cohort_experience_version,
        coach_persona_version: [
          { behavioral_preview_evidence: :release_candidate },
          :coach_persona,
          { release_candidate: :phrase_audience_attestations },
          { evaluation_run: [ :release_candidate, { results: :evaluation_case } ] },
          { evaluation_approval: { evaluation_run: [ :release_candidate, { results: :evaluation_case } ] } },
          {
            phrase_artifact_links: {
              coach_persona_phrase_promotion: %i[coach_phrase_proposal coach_phrase_attestation]
            }
          }
        ]
      ).to_a
    end

    def persona_assessment(release, cache)
      key = [ release.persona_mode, release.coach_persona_version_id ]
      return cache.fetch(key) if cache.key?(key)

      unless release.persona_mode == "published_version"
        return cache[key] = {
          evidence_valid: false,
          governed: false,
          runtime_snapshot: Contract.neutral_persona_snapshot
        }
      end

      version = release.coach_persona_version
      evidence_valid = version&.release_evidence_valid? == true
      cache[key] = {
        evidence_valid: evidence_valid,
        governed: release.coach_persona&.archived_at.nil? && version&.sealed? &&
          version.release_gate_version == "gate_v2" && evidence_valid,
        runtime_snapshot: Contract.persona_snapshot(version: version)
      }
    rescue Mia::PersonaSchema::InvalidConfiguration, ArgumentError, KeyError
      cache[key] = {
        evidence_valid: Integrity::UNSET,
        governed: false,
        runtime_snapshot: nil
      }
    end

    def candidate_payload(candidate, latest_release_id:)
      {
        bundle_digest: candidate.bundle_digest,
        assignment_id: candidate.assignment&.id,
        persona_mode: candidate.persona_snapshot.fetch("mode"),
        coach_persona_id: candidate.persona&.id,
        coach_persona_version_id: candidate.persona_version&.id,
        experience_mode: candidate.experience_snapshot.fetch("mode"),
        cohort_experience_version_id: candidate.experience_version&.id,
        tool_registry_version: Contract::TOOL_REGISTRY_VERSION,
        persona_snapshot_digest: Contract.digest(candidate.persona_snapshot),
        experience_snapshot_digest: Contract.digest(candidate.experience_snapshot),
        tool_registry_digest: Contract.digest(candidate.tool_registry_snapshot),
        tool_registry_module_count: candidate.tool_registry_snapshot.fetch("modules").length,
        tool_registry_operation_count: candidate.tool_registry_snapshot.fetch("operations").length,
        expected_latest_release_id: latest_release_id
      }
    end

    def release_authority
      return [ true, "platform_admin" ] if actor&.admin?

      membership = cohort.coach_workspace.coach_workspace_memberships.find_by(user_id: actor&.id)
      permissions = CoachWorkspace::PERMISSIONS.fetch(membership&.role, [])
      [ permissions.include?(:publish) && permissions.include?(:assign), membership&.role ]
    end

    def readiness_checks(candidate)
      [
        {
          id: "assistant_voice",
          label: "Assistant voice",
          ready: candidate.persona_snapshot.fetch("mode") == "published_version" &&
            candidate.blockers.none? { |value| value.match?(/persona/i) },
          evidence: {
            mode: candidate.persona_snapshot.fetch("mode"),
            persona_version_id: candidate.persona_version&.id,
            snapshot_digest: Contract.digest(candidate.persona_snapshot)
          }
        },
        {
          id: "participant_tools",
          label: "Participant tools",
          ready: candidate.experience_snapshot.fetch("mode") == "published_version" &&
            candidate.blockers.none? { |value| value.match?(/participant tools/i) },
          evidence: {
            mode: candidate.experience_snapshot.fetch("mode"),
            experience_version_id: candidate.experience_version&.id,
            snapshot_digest: Contract.digest(candidate.experience_snapshot)
          }
        },
        {
          id: "system_controls",
          label: "System controls",
          ready: true,
          evidence: {
            registry_version: Contract::TOOL_REGISTRY_VERSION,
            registry_digest: Contract.digest(candidate.tool_registry_snapshot),
            operation_count: candidate.tool_registry_snapshot.fetch("operations").length
          }
        },
        {
          id: "participant_cohort",
          label: "Participant cohort check",
          ready: candidate.ambiguous_participant_count.zero?,
          evidence: {
            participant_count: cohort.cohort_memberships.where(role: "participant").count,
            ambiguous_participant_count: candidate.ambiguous_participant_count
          }
        }
      ]
    end

    def restore_blockers(release, latest:, integrity:, ambiguous_participant_count:, persona_governed:)
      blockers = []
      blockers << "The selected release is already the latest sealed record." if release.id == latest&.id
      if latest && secure_match?(release.bundle_digest, latest.bundle_digest) && release.id != latest.id
        blockers << "The selected release bundle is already the latest sealed record."
      end
      blockers << "The selected release failed its immutable evidence check." unless integrity.fetch(:valid)
      blockers << "The selected release is not compatible with the current runtime." unless integrity.fetch(:runtime_compatible)
      if integrity.fetch(:valid)
        blockers.concat(RestoreGovernance.new(
          cohort: cohort,
          source_release: release,
          ambiguous_participant_count: ambiguous_participant_count,
          persona_governed: persona_governed
        ).call)
      end
      blockers.uniq
    end

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
