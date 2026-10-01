module HouseholdFinance
  module Operations
    class Runner
      Result = Struct.new(:execution, :subject, :after_snapshot, :replayed?, keyword_init: true)
      IdempotencyConflict = Class.new(ArgumentError)
      InvalidPreparedOperation = Class.new(ArgumentError)

      def initialize(household, user:, audit_writer: nil)
        @household = household
        @user = user
        @audit_writer = audit_writer
      end

      def run(operation_key:, input:, idempotency_key:, source: "manual", reviewable: nil)
        operation_class = Registry.fetch(operation_key)
        key = normalize_idempotency_key(idempotency_key)
        invocation_fingerprint = invocation_fingerprint_for(
          operation_class,
          input,
          source: source,
          reviewable: reviewable
        )
        ApplicationRecord.transaction do
          household.lock!
          ensure_actor_membership!
          if (existing = household.household_operation_executions.find_by(idempotency_key: key))
            return replay_invocation(existing, invocation_fingerprint) if existing.invocation_fingerprint.present?

            normalized = operation_class.new(household).normalized_input(input).deep_stringify_keys
            return replay_raw(existing, operation_class, normalized, source: source, reviewable: reviewable)
          end
          prepared = operation_class.new(household).prepare(input)
          execute_inside_transaction!(
            prepared,
            idempotency_key: key,
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
          ensure_actor_membership!
          execute_inside_transaction!(prepared, idempotency_key: idempotency_key, source: source, reviewable: reviewable)
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
        key = normalize_idempotency_key(idempotency_key)
        if (existing = household.household_operation_executions.find_by(idempotency_key: key))
          return replay_invocation(existing, invocation_fingerprint) if invocation_fingerprint && existing.invocation_fingerprint.present?

          return replay(existing, request_fingerprint)
        end

        operation = operation_class.new(household)
        subject = operation.execute!(prepared, source: source)
        after_snapshot = operation.after_snapshot(subject, prepared)
        operation.send(:verify_after!, prepared.predicted_after_snapshot, after_snapshot)
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
            normalized_input: prepared.normalized_input,
            before_snapshot: prepared.before_snapshot,
            predicted_after_snapshot: prepared.predicted_after_snapshot,
            after_snapshot: after_snapshot
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
          normalized_input: prepared.normalized_input,
          before_snapshot: prepared.before_snapshot,
          predicted_after_snapshot: prepared.predicted_after_snapshot,
          after_snapshot: after_snapshot,
          completed_at: Time.current
        )
        Result.new(execution: execution, subject: subject, after_snapshot: after_snapshot, replayed?: false)
      end

      def replay(execution, request_fingerprint)
        unless secure_equal?(execution.request_fingerprint, request_fingerprint)
          raise IdempotencyConflict, "That idempotency key was already used for a different household change. Nothing changed."
        end
        subject = execution.subject_type.safe_constantize&.find_by(id: execution.subject_id)
        unless subject_belongs_to_household?(subject)
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
        unless secure_equal?(execution.invocation_fingerprint, invocation_fingerprint)
          raise IdempotencyConflict, "That idempotency key was already used for a different household change. Nothing changed."
        end

        replay(execution, execution.request_fingerprint)
      end

      def subject_belongs_to_household?(subject)
        case subject
        when Household then subject.id == household.id
        when TransactionDraft then subject.household_id == household.id
        when IncomeSource then subject.household_id == household.id
        when IncomeScheduleEntry then subject.income_source.household_id == household.id
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

      def secure_equal?(left, right)
        left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end
    end
  end
end
