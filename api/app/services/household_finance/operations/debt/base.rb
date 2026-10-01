module HouseholdFinance
  module Operations
    module Debt
      class Base < Operations::Base
        private

        def stale_message
          "Debt details changed since Mia drafted this. Ask Mia to prepare a fresh review card. Nothing changed."
        end

        def ensure_plan!(_input); end

        def normalized_label(value)
          label = value.to_s.squish.truncate(120, omission: "…")
          raise ArgumentError, "Debt name is required" if label.blank?
          label
        end

        def normalized_type(value)
          value.to_s.presence_in(::Debt::DEBT_TYPES) || raise(ArgumentError, "Choose a valid debt type")
        end

        def normalize_optional_money(input, value_key, cents_key, label:)
          return { "#{value_key}_known".to_sym => false, cents_key => 0 } if input.key?(value_key) && input[value_key].nil?
          return { "#{value_key}_known".to_sym => false, cents_key => 0 } if input.key?(value_key) && input[value_key].to_s.strip.blank?
          return { "#{value_key}_known".to_sym => true, cents_key => Money.cents!(input[value_key], message: "#{label} must be a number with no more than two decimal places") } if input.key?(value_key)
          return { "#{value_key}_known".to_sym => input.fetch("#{value_key}_known".to_sym), cents_key => Integer(input.fetch(cents_key)) } if input.key?(cents_key)
          {}
        end

        def normalize_apr(value)
          return nil if value.nil? || value.to_s.strip.blank?
          decimal = BigDecimal(value.to_s)
          raise ArgumentError, "APR must be between 0 and 999.99" unless decimal.between?(0, 999.99)
          decimal.to_f
        rescue ArgumentError
          raise ArgumentError, "APR must be between 0 and 999.99"
        end

        def debt_scope(lock:)
          scope = household.debts
          lock ? scope.lock : scope
        end

        def debt_snapshot(debt)
          {
            debt: {
              id: debt.id,
              label: debt.label,
              debt_type: debt.debt_type,
              balance_cents: debt.balance_cents,
              balance_known: debt.balance_known?,
              minimum_payment_cents: debt.minimum_payment_cents,
              minimum_payment_known: debt.minimum_payment_known?,
              interest_rate_percent: debt.interest_rate_percent&.to_f,
              active: debt.active?,
              archived_at: debt.archived_at&.iso8601,
              source_type: debt.source_type,
              source_metadata: debt.source_metadata
            }
          }
        end

        def verify_debt_prediction!(predicted, actual)
          expected = predicted.fetch("debt")
          observed = actual.fetch("debt")
          return true if expected == observed.slice(*expected.keys)
          raise Operations::Runner::InvalidPreparedOperation, "The saved debt did not match the reviewed change. Nothing changed."
        end

        def conflict_ids(label:, debt_type:, excluding_id: nil, lock: false)
          scope = household.debts.active.where(debt_type: debt_type).where("LOWER(label) = ?", label.downcase)
          scope = scope.where.not(id: excluding_id) if excluding_id
          scope = scope.lock if lock
          scope.order(:id).pluck(:id)
        end
      end
    end
  end
end
