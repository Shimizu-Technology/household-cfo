# frozen_string_literal: true

module CohortReleases
  class Sealer
    class Error < StandardError; end
    class NotAuthorized < Error; end
    class ReadOnly < Error; end
    class Incomplete < Error
      attr_reader :blockers

      def initialize(blockers)
        @blockers = blockers
        super(blockers.join(" "))
      end
    end
    class Stale < Error; end
    class RequestConflict < Error; end
    class AlreadyRecorded < Error; end

    def initialize(cohort:, actor:, publication_source: "user")
      @cohort = cohort
      @actor = actor
      @publication_source = publication_source
    end

    def call!(request_key:, expected_bundle_digest: nil, expected_assignment_id: nil,
      expected_persona_version_id: nil, expected_experience_version_id: nil,
      event_type: "release", source_release: nil)
      key = normalize_key(request_key)
      validate_reserved_request_key!(key, event_type)
      cohort.with_lock do
        authorize!
        require_user_preview!(expected_bundle_digest)
        existing = cohort.cohort_releases.find_by(request_key: key)
        replay_digest = expected_bundle_digest.presence || existing&.bundle_digest
        replay_fingerprint = request_fingerprint(
          key: key,
          bundle_digest: replay_digest,
          event_type: event_type,
          source_release_id: source_release&.id,
          expected_assignment_id: expected_assignment_id,
          expected_persona_version_id: expected_persona_version_id,
          expected_experience_version_id: expected_experience_version_id
        )
        return reconcile!(existing, replay_fingerprint) if existing

        validate_source!(event_type, source_release)
        candidate = candidate_for(event_type, source_release)
        raise Incomplete, candidate.blockers if candidate.blockers.any?
        verify_expectations!(candidate, expected_bundle_digest, expected_assignment_id,
          expected_persona_version_id, expected_experience_version_id)
        reject_noop!(candidate, event_type, source_release)

        fingerprint = request_fingerprint(
          key: key,
          bundle_digest: candidate.bundle_digest,
          event_type: event_type,
          source_release_id: source_release&.id,
          expected_assignment_id: expected_assignment_id,
          expected_persona_version_id: expected_persona_version_id,
          expected_experience_version_id: expected_experience_version_id
        )
        released_at = Time.current
        number = cohort.cohort_releases.maximum(:release_number).to_i + 1
        release_manifest = Contract.manifest(
          release_number: number,
          publication_source: publication_source,
          event_type: event_type,
          released_by_user_id: actor&.id,
          actor_role_snapshot: actor_role_snapshot,
          source_release_id: source_release&.id,
          request_key: key,
          request_fingerprint: fingerprint,
          released_at: released_at,
          bundle_digest: candidate.bundle_digest
        )

        cohort.cohort_releases.create!(
          coach_workspace: cohort.coach_workspace,
          release_number: number,
          publication_source: publication_source,
          event_type: event_type,
          released_by_user: actor,
          actor_role_snapshot: actor_role_snapshot,
          source_release: source_release,
          persona_mode: candidate.persona_snapshot.fetch("mode"),
          coach_persona: candidate.persona,
          coach_persona_version: candidate.persona_version,
          persona_snapshot: candidate.persona_snapshot,
          persona_snapshot_digest: Contract.digest(candidate.persona_snapshot),
          experience_mode: candidate.experience_snapshot.fetch("mode"),
          cohort_experience_configuration: candidate.experience_configuration,
          cohort_experience_version: candidate.experience_version,
          experience_snapshot: candidate.experience_snapshot,
          experience_snapshot_digest: Contract.digest(candidate.experience_snapshot),
          tool_registry_version: Contract::TOOL_REGISTRY_VERSION,
          tool_registry_snapshot: candidate.tool_registry_snapshot,
          tool_registry_digest: Contract.digest(candidate.tool_registry_snapshot),
          manifest_schema: Contract::MANIFEST_SCHEMA,
          bundle: candidate.bundle,
          bundle_digest: candidate.bundle_digest,
          manifest: release_manifest,
          manifest_digest: Contract.digest(release_manifest),
          request_key: key,
          request_fingerprint: fingerprint,
          released_at: released_at
        )
      end
    rescue ActiveRecord::RecordNotUnique
      existing = cohort.cohort_releases.find_by(request_key: key)
      raise unless existing

      reconcile!(existing, request_fingerprint(
        key: key,
        bundle_digest: expected_bundle_digest.presence || existing.bundle_digest,
        event_type: event_type,
        source_release_id: source_release&.id,
        expected_assignment_id: expected_assignment_id,
        expected_persona_version_id: expected_persona_version_id,
        expected_experience_version_id: expected_experience_version_id
      ))
    end

    private

    attr_reader :cohort, :actor, :publication_source, :actor_role_snapshot

    def authorize!
      if publication_source == "user"
        persisted_actor, role = Authorization.new(cohort: cohort, actor: actor).call!
        @actor = persisted_actor
        @actor_role_snapshot = role
        unless cohort.status.in?(CohortRelease::USER_RELEASE_COHORT_STATUSES)
          raise ReadOnly, "Completed and archived cohorts are read-only"
        end
      elsif !publication_source.in?(%w[legacy_backfill system]) || actor.present?
        raise NotAuthorized, "System release evidence cannot be attributed to a user"
      end
    rescue Authorization::NotAuthorized => error
      raise NotAuthorized, error.message
    end

    def require_user_preview!(expected_bundle_digest)
      if publication_source == "user" && expected_bundle_digest.blank?
        raise Stale, "Preview the exact cohort release before sealing it"
      end
    end

    def verify_expectations!(candidate, expected_bundle_digest, expected_assignment_id,
      expected_persona_version_id, expected_experience_version_id)
      checks = [
        [ expected_bundle_digest, candidate.bundle_digest ],
        [ normalized_id(expected_assignment_id), candidate.assignment&.id ],
        [ normalized_id(expected_persona_version_id), candidate.persona_version&.id ],
        [ normalized_id(expected_experience_version_id), candidate.experience_version&.id ]
      ]
      mismatch = checks.any? { |expected, actual| !expected.nil? && expected != actual }
      raise Stale, "The cohort release inputs changed; reload before sealing" if mismatch
    end

    def candidate_for(event_type, source_release)
      return CandidateBuilder.new(cohort: cohort, strict: publication_source == "user").call unless event_type == "restore"

      integrity = source_release.integrity_report
      raise Stale, "The restore source failed its immutable evidence check" unless integrity.fetch(:valid)
      raise Incomplete, [ "The restore source is not compatible with the current runtime." ] unless integrity.fetch(:runtime_compatible)
      if publication_source == "user"
        blockers = RestoreGovernance.new(cohort: cohort, source_release: source_release).call
        raise Incomplete, blockers if blockers.any?
      end

      CandidateBuilder::Candidate.new(
        cohort: cohort,
        assignment: nil,
        persona: source_release.coach_persona,
        persona_version: source_release.coach_persona_version,
        experience_configuration: source_release.cohort_experience_configuration,
        experience_version: source_release.cohort_experience_version,
        persona_snapshot: source_release.persona_snapshot.deep_dup,
        experience_snapshot: source_release.experience_snapshot.deep_dup,
        tool_registry_snapshot: source_release.tool_registry_snapshot.deep_dup,
        bundle: source_release.bundle.deep_dup,
        bundle_digest: source_release.bundle_digest,
        blockers: [],
        warnings: [],
        ambiguous_participant_count: 0
      )
    end

    def validate_source!(event_type, source_release)
      if event_type == "restore"
        unless source_release&.cohort_id == cohort.id && source_release.coach_workspace_id == cohort.coach_workspace_id
          raise Stale, "The restore source does not belong to this cohort"
        end
      elsif source_release
        raise Stale, "A source release is only valid for a restore"
      end
    end

    def reject_noop!(candidate, event_type, source_release)
      return unless publication_source == "user"

      latest = cohort.cohort_releases.order(release_number: :desc).first
      return unless latest

      if event_type == "restore" && source_release.id == latest.id
        raise AlreadyRecorded, "The selected release is already the latest sealed record"
      end
      return unless secure_match?(candidate.bundle_digest, latest.bundle_digest)

      message = if event_type == "restore"
        "The selected release bundle is already the latest sealed record"
      else
        "This exact cohort release bundle is already sealed"
      end
      raise AlreadyRecorded, message
    end

    def reconcile!(existing, fingerprint)
      return existing if secure_match?(existing.request_fingerprint, fingerprint)

      raise RequestConflict, "This request key was already used for a different cohort release"
    end

    def request_fingerprint(key:, bundle_digest:, event_type:, source_release_id:, expected_assignment_id:,
      expected_persona_version_id:, expected_experience_version_id:)
      Contract.digest(
        "schema" => "cohort_release_request_v1",
        "cohort_id" => cohort.id,
        "actor_id" => actor&.id,
        "actor_role_snapshot" => actor_role_snapshot,
        "publication_source" => publication_source,
        "event_type" => event_type,
        "source_release_id" => source_release_id,
        "request_key" => key,
        "bundle_digest" => bundle_digest,
        "expected_assignment_id" => normalized_id(expected_assignment_id),
        "expected_persona_version_id" => normalized_id(expected_persona_version_id),
        "expected_experience_version_id" => normalized_id(expected_experience_version_id)
      )
    end

    def normalize_key(value)
      key = value.to_s.strip
      raise ArgumentError, "request_key must be between 1 and 100 characters" unless key.length.between?(1, 100)

      key
    end

    def validate_reserved_request_key!(key, event_type)
      return unless key == CohortRelease::LEGACY_RECONCILIATION_REQUEST_KEY
      return if publication_source == "legacy_backfill" && event_type == "reconciliation"

      raise ArgumentError, "request_key is reserved for legacy reconciliation"
    end

    def normalized_id(value)
      return nil if value.nil?

      Integer(value, exception: false) || :invalid
    end

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
