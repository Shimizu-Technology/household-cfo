require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      class PlaidLink < Base
        KEY = "account.plaid.link"
        VERSION = 1

        private

        def normalize(input) = { account_id: Integer(input.fetch(:account_id)), plaid_account_id: Integer(input.fetch(:plaid_account_id)) }
        def subject_for(input, lock:) = account_scope(lock: lock).find(input[:account_id])

        def canonical_snapshot(account, input, lock:)
          plaid = plaid_scope(lock: lock).find(input[:plaid_account_id])
          account_snapshot(account).merge(plaid_observation: plaid_snapshot(plaid))
        end

        def predicted_after(before, input)
          { account: before.fetch("account").merge("plaid_account_id" => input[:plaid_account_id], "plaid_reconciled_at" => nil), plaid_observation: before.fetch("plaid_observation") }
        end

        def validate_execution!(account, input, prepared:, source:)
          observation = prepared.before_snapshot.fetch("plaid_observation")
          raise ArgumentError, "Restore this account before matching it" unless account.active?
          raise ArgumentError, "This account is already matched to a bank observation" if account.plaid_account_id
          raise ArgumentError, "That bank account is already matched" if observation["linked_account_id"]
          raise ArgumentError, "That bank account cannot be used as an asset" unless observation.fetch("eligible")
          raise ArgumentError, "Sync or reconnect that bank account before matching it" unless observation.fetch("active") && observation.fetch("item_status") == "active"
          raise ArgumentError, "Choose a compatible household account" unless observation.fetch("allowed_account_types").include?(account.account_type)
        end

        def mutate!(account, input, prepared:)
          account.update!(plaid_account_id: input[:plaid_account_id], plaid_reconciled_at: nil)
          account
        end

        def canonical_after_snapshot(account, _input, prepared:) = account_snapshot(account.reload)
        def verify_after!(predicted, actual) = verify_account_prediction!(predicted, actual)
      end
    end
  end
end
