require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      class RecordUpdate < Base
        KEY = "account.record.update"
        VERSION = 1

        private

        def normalize(input)
          values = { account_id: Integer(input.fetch(:account_id)) }
          values[:label] = normalized_label(input[:label]) if input.key?(:label)
          values[:account_type] = normalized_type(input[:account_type]) if input.key?(:account_type)
          if input.key?(:balance) || input.key?(:balance_cents) || input.key?(:balance_state)
            balance_values = normalize_balance(input)
            balance_values.delete(:balance_as_of_on) if balance_values[:balance_known] && !input.key?(:balance_as_of_on)
            values.merge!(balance_values)
          end
          if input.key?(:balance_as_of_on) && !values.key?(:balance_as_of_on)
            values[:balance_as_of_on] = parsed_date(input[:balance_as_of_on])&.iso8601
          end
          raise ArgumentError, "Choose at least one account field to update" if values.one?
          values
        end

        def subject_for(input, lock:)
          account_scope(lock: lock).find(input[:account_id])
        end

        def canonical_snapshot(account, input, lock:)
          label = input[:label] || account.label
          type = input[:account_type] || account.account_type
          account_snapshot(account).merge(conflicting_account_ids: conflict_ids(label: label, account_type: type, excluding_id: account.id, lock: lock))
        end

        def predicted_after(before, input)
          account = before.fetch("account").merge(input.except(:account_id).stringify_keys)
          account["source_type"] = "mia" if input[:source_type] == "mia"
          { account: account, conflicting_account_ids: before.fetch("conflicting_account_ids") }
        end

        def validate_execution!(account, input, prepared:, source:)
          raise ArgumentError, "Restore this account before editing it. Nothing changed." unless account.active?
          raise ArgumentError, "An active account already uses that name and type. Nothing changed." if prepared.before_snapshot.fetch("conflicting_account_ids").any?
          validate_balance_type!(prepared.predicted_after_snapshot.fetch("account").deep_symbolize_keys)
          predicted_account = prepared.predicted_after_snapshot.fetch("account")
          if input[:balance_as_of_on].present? && !predicted_account.fetch("balance_known")
            raise ArgumentError, "Enter the account balance before adding a balance date"
          end
          if account.plaid_account && input[:account_type] && !PlaidIntegration::AccountEligibility.new(account.plaid_account).allowed_account_types.include?(input[:account_type])
            raise ArgumentError, "Unlink the bank observation before changing to an incompatible account type"
          end
        end

        def mutate!(account, input, prepared:)
          attrs = input.except(:account_id, :source_type)
          attrs[:source_type] = "mia" if input[:source_type] == "mia"
          account.update!(attrs)
          account
        end

        def canonical_after_snapshot(account, _input, prepared:)
          account_snapshot(account.reload)
        end

        def verify_after!(predicted, actual)
          verify_account_prediction!(predicted, actual)
        end
      end
    end
  end
end
