module HouseholdFinance
  module Operations
    module Account
      class Base < Operations::Base
        private

        def ensure_plan!(_input); end

        def stale_message
          "Account details or the bank observation changed since this review was prepared. Prepare a fresh review. Nothing changed."
        end

        def normalized_label(value)
          label = value.to_s.squish.truncate(120, omission: "…")
          raise ArgumentError, "Account name is required" if label.blank?
          label
        end

        def normalized_type(value)
          value.to_s.presence_in(::Account::ACCOUNT_TYPES) || raise(ArgumentError, "Choose a valid account type")
        end

        def normalize_balance(input, required: false)
          state = input[:balance_state].to_s.presence
          if state.nil? && input.key?(:balance_known)
            known = input[:balance_known]
            raise ArgumentError, "Balance known flag must be true or false" unless known == true || known == false
            state = known ? "known" : "unknown"
          end
          state ||= input.key?(:balance) ? (input[:balance].nil? ? "unknown" : "known") : nil
          state ||= "known" if input.key?(:balance_cents)
          raise ArgumentError, "Choose whether the balance is known or unknown" if required && state.nil?
          return {} if state.nil? || state == "unchanged"
          return { balance_known: false, balance_cents: 0, balance_as_of_on: nil } if state == "unknown"
          raise ArgumentError, "Choose a valid balance state" unless state == "known"

          cents = input.key?(:balance_cents) ? Integer(input[:balance_cents]) : signed_cents(input[:balance])
          { balance_known: true, balance_cents: cents, balance_as_of_on: parsed_date(input[:balance_as_of_on])&.iso8601 }
        end

        def signed_cents(value)
          text = value.to_s.strip
          raise ArgumentError, "Balance must be a number with no more than two decimal places" unless text.match?(/\A-?\d{1,9}(?:\.\d{1,2})?\z/)
          (BigDecimal(text) * 100).round.to_i
        end

        def parsed_date(value)
          return nil if value.blank?
          Date.iso8601(value.to_s)
        rescue Date::Error
          raise ArgumentError, "Balance date must be a valid date"
        end

        def account_scope(lock:)
          scope = household.accounts
          lock ? scope.lock : scope
        end

        def plaid_scope(lock:)
          scope = PlaidAccount.joins(:plaid_item).where(plaid_items: { household_id: household.id })
          lock ? scope.lock : scope
        end

        def account_snapshot(account)
          {
            account: {
              id: account.id, label: account.label, account_type: account.account_type,
              balance_cents: account.balance_cents, balance_known: account.balance_known?,
              balance_as_of_on: account.balance_as_of_on&.iso8601,
              active: account.active?, archived_at: account.archived_at&.iso8601,
              source_type: account.source_type, source_metadata: account.source_metadata,
              plaid_account_id: account.plaid_account_id,
              plaid_reconciled_at: account.plaid_reconciled_at&.iso8601
            }
          }
        end

        def plaid_snapshot(plaid_account)
          return nil unless plaid_account
          eligibility = PlaidIntegration::AccountEligibility.new(plaid_account)
          {
            id: plaid_account.id, active: plaid_account.active?, item_status: plaid_account.plaid_item.status,
            account_type: plaid_account.account_type, account_subtype: plaid_account.account_subtype,
            current_balance_cents: plaid_account.current_balance_cents,
            available_balance_cents: plaid_account.available_balance_cents,
            last_synced_at: plaid_account.plaid_item.last_synced_at&.iso8601,
            eligible: eligibility.eligible?, allowed_account_types: eligibility.allowed_account_types,
            linked_account_id: plaid_account.account&.id
          }
        end

        def conflict_ids(label:, account_type:, excluding_id: nil, lock: false)
          scope = household.accounts.active.where(account_type: account_type).where("LOWER(label) = ?", label.downcase)
          scope = scope.where.not(id: excluding_id) if excluding_id
          scope = scope.lock if lock
          scope.order(:id).pluck(:id)
        end

        def validate_balance_type!(attributes)
          return unless attributes[:balance_known] && attributes[:balance_cents].to_i.negative?
          return if attributes[:account_type].to_s.in?(::Account::SIGNED_BALANCE_TYPES)
          raise ArgumentError, "Only checking or savings can have a negative balance"
        end

        def verify_account_prediction!(predicted, actual)
          expected = predicted.fetch("account")
          observed = actual.fetch("account")
          return true if expected == observed.slice(*expected.keys)
          raise Operations::Runner::InvalidPreparedOperation, "The saved account did not match the reviewed change. Nothing changed."
        end
      end
    end
  end
end
