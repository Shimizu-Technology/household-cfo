module HouseholdFinance
  module Operations
    class Runner
      Result = Struct.new(:execution, :subject, :after_snapshot, :replayed?, keyword_init: true)
      IdempotencyConflict = Class.new(ArgumentError)
      InvalidPreparedOperation = Class.new(ArgumentError)

      def initialize(household, user:, audit_writer: nil, cohort_membership: nil)
        @household = household
        @user = user
        @audit_writer = audit_writer
        @cohort_membership = cohort_membership
      end

      def run(operation_key:, input:, idempotency_key:, source: "manual", reviewable: nil)
        operation_class = Registry.fetch(operation_key)
        key = storage_idempotency_key(operation_class, idempotency_key)
        invocation_fingerprint = invocation_fingerprint_for(
          operation_class,
          input,
          source: source,
          reviewable: reviewable
        )
        ApplicationRecord.transaction do
          household.lock!
          FinancialGenerationGuard.request!(household)
          ensure_actor_membership!
          if (existing = household.household_operation_executions.find_by(idempotency_key: key))
            return replay_invocation(existing, invocation_fingerprint) if existing.invocation_fingerprint.present?

            normalized = build_operation(operation_class).normalized_input(input).deep_stringify_keys
            return replay_raw(existing, operation_class, normalized, source: source, reviewable: reviewable)
          end
          prepared = build_operation(operation_class).prepare(input)
          execute_inside_transaction!(
            prepared,
            idempotency_key: idempotency_key,
            source: source,
            reviewable: reviewable,
            invocation_fingerprint: invocation_fingerprint
          )
        end
      end

      def run_prepared(prepared:, prepared_fingerprint:, idempotency_key:, source: "mia", reviewable: nil)
        prepared = PreparedOperation.from_hash(prepared)
        unless secure_equal?(prepared.fingerprint, prepared_fingerprint.to_s)
          raise InvalidPreparedOperation, "Mia’s review card no longer matches its prepared operation. Ask Mia to draft a fresh edit. Nothing changed."
        end

        ApplicationRecord.transaction do
          household.lock!
          FinancialGenerationGuard.request!(household)
          ensure_actor_membership!
          execute_inside_transaction!(prepared, idempotency_key: idempotency_key, source: source, reviewable: reviewable)
        end
      end

      # Resolve an interrupted private request without retaining financial input
      # in browser storage or returning generic execution/audit snapshots.
      def private_request_result(operation_key:, idempotency_key:)
        operation_class = Registry.fetch(operation_key)
        raise InvalidPreparedOperation, "Only actor-scoped private requests can be resolved" unless actor_required?(operation_class) && sensitive_operation?(operation_class)
        ApplicationRecord.transaction do
          household.lock!
          FinancialGenerationGuard.request!(household)
          ensure_actor_membership!
          execution = household.household_operation_executions.find_by(idempotency_key: storage_idempotency_key(operation_class, idempotency_key))
          return nil unless execution
          unless execution.user_id == user.id && execution.operation_key == operation_key
            raise IdempotencyConflict, "This request identity belongs to a different private operation."
          end
          subject = execution.subject_type.safe_constantize&.find_by(id: execution.subject_id)
          raise InvalidPreparedOperation, "The private request result is unavailable" unless subject
          build_operation(operation_class).authorize_replay!(subject)
          Result.new(execution: execution, subject: subject, after_snapshot: {}, replayed?: true)
        end
      end

      private

      attr_reader :household, :user, :audit_writer

      def execute_inside_transaction!(prepared, idempotency_key:, source:, reviewable:, invocation_fingerprint: nil)
        unless prepared.household_id.to_i == household.id
          raise InvalidPreparedOperation, "This household operation belongs to a different household. Nothing changed."
        end
        operation_class = Registry.fetch(prepared.operation_key, prepared.operation_version)
        request_fingerprint = request_fingerprint_for(prepared, source: source, reviewable: reviewable)
        key = storage_idempotency_key(operation_class, idempotency_key)
        if (existing = household.household_operation_executions.find_by(idempotency_key: key))
          return replay_invocation(existing, invocation_fingerprint) if invocation_fingerprint && existing.invocation_fingerprint.present?

          return replay(existing, request_fingerprint)
        end

        operation = build_operation(operation_class)
        subject = operation.execute!(prepared, source: source)
        after_snapshot = operation.after_snapshot(subject, prepared)
        operation.send(:verify_after!, prepared.predicted_after_snapshot, after_snapshot)
        mirrored = if sensitive_operation?(operation_class)
          { normalized_input: {}, before_snapshot: {}, predicted_after_snapshot: {}, after_snapshot: {} }
        else
          { normalized_input: prepared.normalized_input, before_snapshot: prepared.before_snapshot,
            predicted_after_snapshot: prepared.predicted_after_snapshot, after_snapshot: after_snapshot }
        end
        audit_attributes = {
          user: user,
          actor_type: "user",
          event_type: "household_operation.executed",
          auditable_type: reviewable&.class&.name || subject.class.name,
          auditable_id: reviewable&.id || subject.id,
          occurred_at: Time.current,
          metadata: {
            operation_key: prepared.operation_key,
            operation_version: prepared.operation_version,
            source: source,
            idempotency_key: key,
            **mirrored
          }
        }
        audit = audit_writer ? audit_writer.call(audit_attributes) : household.household_audit_events.create!(audit_attributes)
        execution = household.household_operation_executions.create!(
          user: user,
          household_audit_event: audit,
          reviewable: reviewable,
          operation_key: prepared.operation_key,
          operation_version: prepared.operation_version,
          idempotency_key: key,
          request_fingerprint: request_fingerprint,
          invocation_fingerprint: invocation_fingerprint,
          source: source,
          status: "completed",
          subject_type: subject.class.name,
          subject_id: subject.id,
          **mirrored,
          completed_at: Time.current
        )
        Result.new(execution: execution, subject: subject, after_snapshot: after_snapshot, replayed?: false)
      end

      def replay(execution, request_fingerprint)
        if financial_operation?(execution.operation_key) && execution.financial_generation != household.financial_generation
          raise InvalidPreparedOperation, "This operation belongs to your previous financial picture. Nothing changed."
        end
        unless secure_equal?(execution.request_fingerprint, request_fingerprint)
          raise IdempotencyConflict, "That idempotency key was already used for a different household change. Nothing changed."
        end
        subject = execution.subject_type.safe_constantize&.find_by(id: execution.subject_id)
        operation_class = Registry.fetch(execution.operation_key, execution.operation_version)
        if actor_required?(operation_class)
          unless subject && execution.user_id == user.id
            raise InvalidPreparedOperation, "The original private operation is unavailable for this participant. Nothing changed."
          end
          operation = build_operation(operation_class)
          unless operation.respond_to?(:authorize_replay!)
            raise InvalidPreparedOperation, "The private operation does not support authorized replay. Nothing changed."
          end
          operation.authorize_replay!(subject)
        elsif !subject_belongs_to_household?(subject)
          raise InvalidPreparedOperation, "The original household operation subject is no longer available. Nothing changed."
        end
        Result.new(execution: execution, subject: subject, after_snapshot: execution.after_snapshot, replayed?: true)
      end

      def replay_raw(execution, operation_class, normalized_input, source:, reviewable:)
        expected_reviewable = reviewable && [ reviewable.class.name, reviewable.id ]
        actual_reviewable = execution.reviewable && [ execution.reviewable_type, execution.reviewable_id ]
        unless execution.operation_key == operation_class::KEY && execution.operation_version == operation_class::VERSION &&
            execution.user_id == user.id && execution.source == source.to_s && actual_reviewable == expected_reviewable &&
            execution.normalized_input == normalized_input
          raise IdempotencyConflict, "That idempotency key was already used for a different household change. Nothing changed."
        end

        replay(execution, execution.request_fingerprint)
      end

      def replay_invocation(execution, invocation_fingerprint)
        if financial_operation?(execution.operation_key) && execution.financial_generation != household.financial_generation
          raise InvalidPreparedOperation, "This operation belongs to your previous financial picture. Nothing changed."
        end
        unless secure_equal?(execution.invocation_fingerprint, invocation_fingerprint)
          raise IdempotencyConflict, "That idempotency key was already used for a different household change. Nothing changed."
        end

        replay(execution, execution.request_fingerprint)
      end

      def financial_operation?(key)
        key.start_with?("income.", "debt.", "account.", "goal.", "budget.", "profile.", "transaction.", "baseline.", "source_review.")
      end

      def subject_belongs_to_household?(subject)
        case subject
        when Household then subject.id == household.id
        when TransactionDraft then subject.household_id == household.id
        when IncomeSource then subject.household_id == household.id
        when IncomeScheduleEntry then subject.income_source.household_id == household.id
        when ::Debt then subject.household_id == household.id
        when ::Account then subject.household_id == household.id
        when ::Goal then subject.household_id == household.id
        when HouseholdProfile then subject.household_id == household.id
        when BudgetCategory then subject.household_id == household.id
        when BudgetAllocation then subject.budget_category.household_id == household.id && subject.budget_period.budget_year.household_id == household.id
        else false
        end
      end

      def request_fingerprint_for(prepared, source:, reviewable:)
        PreparedOperation.fingerprint(
          household_id: household.id,
          user_id: user.id,
          source: source.to_s,
          reviewable: reviewable && { type: reviewable.class.name, id: reviewable.id },
          operation_key: prepared.operation_key,
          operation_version: prepared.operation_version,
          subject: prepared.subject,
          year: prepared.normalized_input["year"],
          normalized_input: prepared.normalized_input
        )
      end

      def invocation_fingerprint_for(operation_class, input, source:, reviewable:)
        PreparedOperation.fingerprint(
          household_id: household.id,
          user_id: user.id,
          source: source.to_s,
          reviewable: reviewable && { type: reviewable.class.name, id: reviewable.id },
          operation_key: operation_class::KEY,
          operation_version: operation_class::VERSION,
          input: input.to_h.deep_stringify_keys
        )
      end

      def ensure_actor_membership!
        membership = household.household_memberships.lock.find_by(user_id: user.id)
        return if membership&.role.in?(%w[owner partner])

        raise InvalidPreparedOperation, "You no longer have permission to change this household. Nothing changed."
      end

      def normalize_idempotency_key(value)
        key = value.to_s.strip
        raise ArgumentError, "Idempotency key is required" if key.blank?
        raise ArgumentError, "Idempotency key is too long" if key.length > 200
        key
      end

      def build_operation(operation_class)
        operation = actor_required?(operation_class) ? operation_class.new(household, user: user) : operation_class.new(household)
        operation.release_membership = @cohort_membership if operation.respond_to?(:release_membership=)
        operation
      end

      def actor_required?(operation_class)
        operation_class.const_defined?(:ACTOR_REQUIRED) && operation_class::ACTOR_REQUIRED == true
      end

      def sensitive_operation?(operation_class)
        operation_class.const_defined?(:SENSITIVE_AUDIT) && operation_class::SENSITIVE_AUDIT == true
      end

      def storage_idempotency_key(operation_class, value)
        key = normalize_idempotency_key(value)
        return key unless sensitive_operation?(operation_class)

        # Callers sometimes put financial text into a key. Keep it out of generic
        # audit/execution rows without losing actor-scoped invocation identity.
        "private:#{PreparedOperation.fingerprint(user_id: user.id, key: key)}"
      end

      def secure_equal?(left, right)
        left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end
    end
  end
end
