require_relative "base"

module HouseholdFinance
  module Operations
    module Debt
      class RecordCreate < Base
        KEY = "debt.record.create"
        VERSION = 1

        private

        def normalize(input)
          values = {
            label: normalized_label(input[:label]),
            debt_type: normalized_type(input[:debt_type].presence || "other"),
            interest_rate_percent: normalize_apr(input[:interest_rate_percent]),
            source_type: input[:source_type].to_s.presence_in(::Debt::SOURCE_TYPES) || "manual_ui",
            source_metadata: input[:source_metadata].is_a?(Hash) ? input[:source_metadata] : {}
          }
          values.merge!(normalize_optional_money(input, :balance, :balance_cents, label: "Balance"))
          values.merge!(normalize_optional_money(input, :minimum_payment, :minimum_payment_cents, label: "Minimum payment"))
          values[:balance_known] = false unless values.key?(:balance_known)
          values[:balance_cents] = 0 unless values.key?(:balance_cents)
          values[:minimum_payment_known] = false unless values.key?(:minimum_payment_known)
          values[:minimum_payment_cents] = 0 unless values.key?(:minimum_payment_cents)
          values
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          { debt: nil, conflicting_debt_ids: conflict_ids(label: input.fetch(:label), debt_type: input.fetch(:debt_type), lock: lock) }
        end

        def predicted_after(before, input)
          { debt: input.slice(:label, :debt_type, :balance_cents, :balance_known, :minimum_payment_cents, :minimum_payment_known, :interest_rate_percent, :source_type, :source_metadata).merge(active: true, archived_at: nil), conflicting_debt_ids: before.fetch("conflicting_debt_ids") }
        end

        def mutate!(_household, input, prepared:)
          if prepared.before_snapshot.fetch("conflicting_debt_ids").any?
            raise ArgumentError, "An active debt already uses that name and type. Edit it or choose a different name. Nothing changed."
          end
          household.debts.create!(input.slice(:label, :debt_type, :balance_cents, :balance_known, :minimum_payment_cents, :minimum_payment_known, :interest_rate_percent, :source_type, :source_metadata).merge(active: true, archived_at: nil))
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
