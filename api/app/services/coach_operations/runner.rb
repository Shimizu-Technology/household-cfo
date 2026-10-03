# frozen_string_literal: true

module CoachOperations
  class Runner
    ROLLOUT_ROSTER_CONSTRAINT = "cohort_rollout_roster_matches_current_participants"
    ROLLOUT_LATEST_RELEASE_CONSTRAINT = "cohort_rollout_target_is_latest_release"

    Result = Data.define(:execution, :release, :rollout, :transition, :replayed) do
      def record
        release || transition
      end
    end
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

      Cohort.transaction do
        locked_cohort = Cohort.lock.find(cohort.id)
        locked_actor, actor_role = authorize!(locked_cohort)
        existing = locked_cohort.coach_operation_executions.find_by(request_key: key)
        if existing
          unless existing.operation_key == operation_key.to_s
            raise IdempotencyConflict, "This Idempotency-Key was already used for a different coach operation"
          end

          operation_class = Registry.fetch(existing.operation_key, version: existing.operation_version)
          operation = build_operation(
            operation_class,
            locked_cohort,
            locked_actor,
            actor_role,
            operation_version: existing.operation_version
          )
          prepared = operation.prepare(input)
          request_fingerprint = request_fingerprint_for(prepared, key, locked_cohort, locked_actor, actor_role)
          return replay(existing, request_fingerprint)
        end

        operation_class = Registry.fetch(operation_key, version: operation_version)
        replay_only_versions = if operation_class.const_defined?(:REPLAY_ONLY_VERSIONS, false)
          operation_class::REPLAY_ONLY_VERSIONS
        else
          []
        end
        if Integer(operation_version, exception: false).in?(replay_only_versions)
          raise InvalidRequest, "New coach operations must use version #{operation_class::VERSION}"
        end
        operation = build_operation(
          operation_class,
          locked_cohort,
          locked_actor,
          actor_role,
          operation_version: operation_version
        )
        prepared = operation.prepare(input)
        invocation_fingerprint = invocation_fingerprint_for(prepared, locked_cohort, locked_actor, actor_role)
        request_fingerprint = Contract.request_fingerprint(request_key: key, invocation_fingerprint: invocation_fingerprint)

        operation_result = operation.execute!(prepared, request_key: key)
        evidence = operation_evidence(operation, prepared, operation_result)
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
          before_snapshot: evidence.fetch(:before_snapshot),
          before_snapshot_digest: Contract.digest(evidence.fetch(:before_snapshot)),
          predicted_after_snapshot: evidence.fetch(:predicted_after_snapshot),
          predicted_after_snapshot_digest: Contract.digest(evidence.fetch(:predicted_after_snapshot)),
          after_snapshot: evidence.fetch(:after_snapshot),
          after_snapshot_digest: Contract.digest(evidence.fetch(:after_snapshot)),
          cohort_release: evidence[:release],
          cohort_rollout_transition: evidence[:transition],
          completed_at: evidence.fetch(:completed_at)
        )
        result_for(execution, replayed: false)
      end
    rescue CohortReleases::Authorization::NotAuthorized => error
      raise NotAuthorized, error.message
    rescue KeyError, Base::InvalidInput => error
      raise InvalidRequest, error.message
    rescue ActiveRecord::StatementInvalid => error
      case database_constraint_name(error)
      when ROLLOUT_ROSTER_CONSTRAINT
        raise CohortRollouts::StateMachine::Stale,
          "The participant roster changed; reload before planning."
      when ROLLOUT_LATEST_RELEASE_CONSTRAINT
        raise CohortRollouts::StateMachine::Stale,
          "The latest sealed release changed; reload before planning."
      end

      raise
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

    def request_fingerprint_for(prepared, key, locked_cohort, locked_actor, actor_role)
      Contract.request_fingerprint(
        request_key: key,
        invocation_fingerprint: invocation_fingerprint_for(prepared, locked_cohort, locked_actor, actor_role)
      )
    end

    def build_operation(operation_class, locked_cohort, locked_actor, actor_role, operation_version:)
      operation_class.new(
        cohort: locked_cohort,
        actor: locked_actor,
        actor_role_snapshot: actor_role,
        operation_version: operation_version
      )
    end

    def replay(existing, request_fingerprint)
      if secure_match?(existing.request_fingerprint, request_fingerprint)
        return result_for(existing, replayed: true)
      end

      raise IdempotencyConflict, "This Idempotency-Key was already used for a different coach operation"
    end

    def operation_evidence(operation, prepared, result)
      if result.respond_to?(:transition) && result.transition
        {
          release: nil,
          transition: result.transition,
          before_snapshot: prepared.before_snapshot,
          predicted_after_snapshot: prepared.predicted_after_snapshot,
          after_snapshot: result.after_snapshot,
          completed_at: result.transition.occurred_at
        }
      else
        {
          release: result,
          transition: nil,
          before_snapshot: prepared.before_snapshot,
          predicted_after_snapshot: prepared.predicted_after_snapshot,
          after_snapshot: operation.after_snapshot(result),
          completed_at: result.released_at
        }
      end
    end

    def result_for(execution, replayed:)
      transition = execution.cohort_rollout_transition
      Result.new(
        execution: execution,
        release: execution.cohort_release,
        rollout: transition&.cohort_rollout,
        transition: transition,
        replayed: replayed
      )
    end

    def secure_match?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def database_constraint_name(error)
      result = error.cause&.respond_to?(:result) ? error.cause.result : nil
      result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
    rescue StandardError
      nil
    end
  end
end
