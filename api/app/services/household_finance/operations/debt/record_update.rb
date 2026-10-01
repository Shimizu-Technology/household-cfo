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
          raise ArgumentError, "Choose at least one debt field to update" if values.one?
          values
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
          changed = before.fetch("debt").merge(input.except(:debt_id).stringify_keys)
          { debt: changed, conflicting_debt_ids: before.fetch("conflicting_debt_ids") }
        end

        def validate_execution!(debt, _input, prepared:, source:)
          raise ArgumentError, "Restore this debt before editing it. Nothing changed." unless debt.active?
          if prepared.before_snapshot.fetch("conflicting_debt_ids").any?
            raise ArgumentError, "An active debt already uses that name and type. Nothing changed."
          end
        end

        def mutate!(debt, input, prepared:)
          debt.update!(input.except(:debt_id))
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
