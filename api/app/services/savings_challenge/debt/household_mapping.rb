module SavingsChallenge
  module Debt
    # This is a deliberately reviewed identity link, never a synchronization.
    # The optional card keeps its own approved, dated terms and provenance.
    class HouseholdMapping
      KEYS = %i[household_debt_id fingerprint].freeze
      def initialize(household) = @household = household

      def normalize(input)
        return nil if input.nil?
        raise ArgumentError, "Review the exact saved household card" unless input.is_a?(Hash)
        input = input.deep_symbolize_keys
        Inputs.keys!(input, required: KEYS)
        raise ArgumentError, "Review the current household card fingerprint" unless input[:fingerprint].instance_of?(String) && input[:fingerprint].match?(/\A[0-9a-f]{64}\z/)
        { household_debt_id: Inputs.id!(input[:household_debt_id]), fingerprint: input[:fingerprint] }
      end

      def resolve!(input)
        return empty if input.nil?
        mapping = normalize(input)
        debt = @household.debts.find(mapping.fetch(:household_debt_id))
        result = candidate(debt)
        raise HouseholdFinance::Operations::Base::StaleOperation, "Saved household card details changed. Review the current values before approving. Nothing changed." unless result && result[:fingerprint] == mapping[:fingerprint]
        { household_debt_id: debt.id, household_debt_fingerprint: result[:fingerprint], household_debt_snapshot: result[:snapshot] }
      end

      def values(record)
        { household_debt_id: record.household_debt_id, household_debt_fingerprint: record.household_debt_fingerprint, household_debt_snapshot: record.household_debt_snapshot }
      end

      def current?(record)
        return true unless record.household_debt_id
        debt = @household.debts.find_by(id: record.household_debt_id)
        current = debt && candidate(debt)
        !!(current && current[:fingerprint] == record.household_debt_fingerprint && current[:snapshot] == record.household_debt_snapshot)
      end

      def candidate(debt)
        return unless debt.household_id == @household.id && debt.active? && debt.debt_type == "credit_card"
        snapshot = debt.attributes.slice("id", "label", "debt_type", "balance_cents", "balance_known", "minimum_payment_cents", "minimum_payment_known", "interest_rate_percent", "active", "archived_at").merge("updated_at" => debt.updated_at.iso8601(6))
        snapshot["interest_rate_percent"] = debt.interest_rate_percent&.to_s("F")
        { household_debt_id: debt.id, label: debt.label, fingerprint: HouseholdFinance::Operations::PreparedOperation.fingerprint(snapshot), snapshot: snapshot,
          proposed_terms: { balance_cents: debt.balance_known? ? debt.balance_cents : nil, minimum_payment_cents: debt.minimum_payment_known? ? debt.minimum_payment_cents : nil,
            apr_bps: debt.interest_rate_percent && (debt.interest_rate_percent * 100).to_i },
          qualifications: [ "These are saved household values, not verified statement terms. Review the date and each value.", "Approving optional card terms does not update household debt or challenge savings." ] }
      end

      private
      def empty = { household_debt_id: nil, household_debt_fingerprint: nil, household_debt_snapshot: {} }
    end
  end
end
