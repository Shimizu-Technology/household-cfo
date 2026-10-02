# frozen_string_literal: true

module CoachOperations
  class Runner
    Result = Data.define(:execution, :release, :replayed)
    class Error < StandardError; end
    class NotAuthorized < Error; end
    class IdempotencyConflict < Error; end
    class InvalidRequest < Error; end

    def initialize(cohort:, actor:)
      @cohort = cohort
      @actor = actor
    end

    def call!(operation_key:, operation_version:, input:, request_key:)
      key = normalize_request_key(request_key)
      operation_class = Registry.fetch(operation_key, version: operation_version)

      Cohort.transaction do
        locked_cohort = Cohort.lock.find(cohort.id)
        locked_actor, actor_role = authorize!(locked_cohort)
        operation = operation_class.new(
          cohort: locked_cohort,
          actor: locked_actor,
          actor_role_snapshot: actor_role
        )
        prepared = operation.prepare(input)
        invocation_fingerprint = invocation_fingerprint_for(prepared, locked_cohort, locked_actor, actor_role)
        request_fingerprint = Contract.request_fingerprint(
          request_key: key,
          invocation_fingerprint: invocation_fingerprint
        )
        existing = locked_cohort.coach_operation_executions.find_by(request_key: key)
        return replay(existing, request_fingerprint) if existing

        release = operation.execute!(prepared, request_key: key)
        after_snapshot = operation.after_snapshot(release)
        execution = locked_cohort.coach_operation_executions.create!(
          coach_workspace: locked_cohort.coach_workspace,
          actor_user: locked_actor,
          actor_role_snapshot: actor_role,
          operation_key: prepared.operation_key,
          operation_version: prepared.operation_version,
          source: "api",
          request_key: key,
          invocation_fingerprint: invocation_fingerprint,
          request_fingerprint: request_fingerprint,
          normalized_input: prepared.normalized_input,
          normalized_input_digest: Contract.digest(prepared.normalized_input),
          before_snapshot: prepared.before_snapshot,
          before_snapshot_digest: Contract.digest(prepared.before_snapshot),
          predicted_after_snapshot: prepared.predicted_after_snapshot,
          predicted_after_snapshot_digest: Contract.digest(prepared.predicted_after_snapshot),
          after_snapshot: after_snapshot,
          after_snapshot_digest: Contract.digest(after_snapshot),
          cohort_release: release,
          completed_at: release.released_at
        )
        Result.new(execution: execution, release: release, replayed: false)
      end
    rescue CohortReleases::Authorization::NotAuthorized => error
      raise NotAuthorized, error.message
    rescue KeyError, Base::InvalidInput => error
      raise InvalidRequest, error.message
    end

    private

    attr_reader :cohort, :actor

    def authorize!(locked_cohort)
      CohortReleases::Authorization.new(cohort: locked_cohort, actor: actor).call!
    end

    def normalize_request_key(value)
      key = value.to_s.strip
      raise InvalidRequest, "Idempotency-Key must be between 1 and 100 characters" unless key.length.between?(1, 100)

      key
    end

    def invocation_fingerprint_for(prepared, locked_cohort, locked_actor, actor_role)
      Contract.invocation_fingerprint(
        cohort_id: locked_cohort.id,
        coach_workspace_id: locked_cohort.coach_workspace_id,
        actor_user_id: locked_actor.id,
        actor_role_snapshot: actor_role,
        operation_key: prepared.operation_key,
        operation_version: prepared.operation_version,
        normalized_input: prepared.normalized_input
      )
    end

    def replay(existing, request_fingerprint)
      if secure_match?(existing.request_fingerprint, request_fingerprint)
        return Result.new(execution: existing, release: existing.cohort_release, replayed: true)
      end

      raise IdempotencyConflict, "This Idempotency-Key was already used for a different coach operation"
    end

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
