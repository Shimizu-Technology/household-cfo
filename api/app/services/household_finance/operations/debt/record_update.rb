require_relative "base"

module HouseholdFinance
  module Operations
    module Debt
      class RecordUpdate < Base
        KEY = "debt.record.update"
        VERSION = 1

        private

        def normalize(input)
          values = { debt_id: Integer(input.fetch(:debt_id)) }
          values[:label] = normalized_label(input[:label]) if input.key?(:label)
          values[:debt_type] = normalized_type(input[:debt_type]) if input.key?(:debt_type)
          values.merge!(normalize_optional_money(input, :balance, :balance_cents, label: "Balance")) if input.key?(:balance) || input.key?(:balance_cents)
          values.merge!(normalize_optional_money(input, :minimum_payment, :minimum_payment_cents, label: "Minimum payment")) if input.key?(:minimum_payment) || input.key?(:minimum_payment_cents)
          values[:interest_rate_percent] = normalize_apr(input[:interest_rate_percent]) if input.key?(:interest_rate_percent)
          values[:due_day] = normalize_due_day(input[:due_day]) if input.key?(:due_day)
          values.merge!(normalize_past_due(input))
          raise ArgumentError, "Choose at least one debt field to update" if values.one?
          expected = normalize_expected(input[:expected])
          values[:expected] = expected if expected.present?
          values
        end

        # What the form showed before she edited each field she changed. A field changed in
        # another tab or by an applied Mia card since then makes this a concurrent edit, so
        # an older form never overwrites it.
        def normalize_expected(raw)
          return {} unless raw.is_a?(Hash)

          raw = raw.to_h.deep_symbolize_keys
          expected = {}
          expected[:label] = normalized_label(raw[:label]) if raw.key?(:label)
          expected[:debt_type] = raw[:debt_type].to_s if raw.key?(:debt_type)
          expected.merge!(normalize_optional_money(raw, :balance, :balance_cents, label: "Balance")) if raw.key?(:balance)
          expected.merge!(normalize_optional_money(raw, :minimum_payment, :minimum_payment_cents, label: "Minimum payment")) if raw.key?(:minimum_payment)
          expected[:interest_rate_percent] = normalize_apr(raw[:interest_rate_percent]) if raw.key?(:interest_rate_percent)
          expected[:due_day] = normalize_due_day(raw[:due_day]) if raw.key?(:due_day)
          expected.merge!(normalize_past_due(raw.slice(:past_due))) if raw.key?(:past_due)
          expected
        end

        def expected_matches?(debt, expected)
          expected.all? do |key, value|
            case key
            when :balance_cents then !debt.balance_known? || debt.balance_cents == value
            when :minimum_payment_cents then !debt.minimum_payment_known? || debt.minimum_payment_cents == value
            when :interest_rate_percent then debt.interest_rate_percent&.to_f == value
            else debt.public_send(key) == value
            end
          end
        end

        def subject_for(input, lock:)
          debt_scope(lock: lock).find(input.fetch(:debt_id))
        end

        def canonical_snapshot(debt, input, lock:)
          snapshot = debt_snapshot(debt)
          label = input[:label] || debt.label
          debt_type = input[:debt_type] || debt.debt_type
          snapshot.merge(conflicting_debt_ids: conflict_ids(label: label, debt_type: debt_type, excluding_id: debt.id, lock: lock))
        end

        def predicted_after(before, input)
          changed = before.fetch("debt").merge(input.except(:debt_id, :expected).stringify_keys)
          { debt: changed, conflicting_debt_ids: before.fetch("conflicting_debt_ids") }
        end

        def validate_execution!(debt, input, prepared:, source:)
          raise ArgumentError, "Restore this debt before editing it. Nothing changed." unless debt.active?
          if input[:expected].present? && !expected_matches?(debt, input[:expected])
            raise ConcurrentEdit, "This debt changed in another tab or on another device. Refresh to see the latest details, then make your change again. Nothing changed."
          end
          if prepared.before_snapshot.fetch("conflicting_debt_ids").any?
            raise ArgumentError, "An active debt already uses that name and type. Nothing changed."
          end
        end

        def mutate!(debt, input, prepared:)
          debt.update!(input.except(:debt_id, :expected))
          debt
        end

        def canonical_after_snapshot(debt, _input, prepared:)
          debt_snapshot(debt.reload)
        end

        def verify_after!(predicted, actual)
          verify_debt_prediction!(predicted, actual)
        end
      end
    end
  end
end
