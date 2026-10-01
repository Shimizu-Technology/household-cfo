require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      class PlaidReconcile < Base
        KEY = "account.plaid.reconcile"
        VERSION = 1
        DECISIONS = %w[accept_observed keep_saved].freeze

        private

        def normalize(input)
          decision = input[:decision].to_s
          raise ArgumentError, "Choose whether to use the bank balance or keep the saved balance" unless decision.in?(DECISIONS)
          { account_id: Integer(input.fetch(:account_id)), decision: decision }
        end

        def subject_for(input, lock:) = account_scope(lock: lock).find(input[:account_id])

        def canonical_snapshot(account, _input, lock:)
          plaid = account.plaid_account_id ? plaid_scope(lock: lock).find(account.plaid_account_id) : nil
          account_snapshot(account).merge(plaid_observation: plaid_snapshot(plaid))
        end

        def predicted_after(before, input)
          observation = before.fetch("plaid_observation")
          account = before.fetch("account").merge("plaid_reconciled_at" => observation.fetch("last_synced_at"))
          if input[:decision] == "accept_observed"
            account.merge!(
              "balance_cents" => observation.fetch("current_balance_cents"), "balance_known" => true,
              "balance_as_of_on" => observation.fetch("last_synced_at").to_s.first(10),
              "source_type" => "plaid"
            )
          end
          { account: account, plaid_observation: observation }
        end

        def validate_execution!(account, input, prepared:, source:)
          observation = prepared.before_snapshot["plaid_observation"]
          raise ArgumentError, "Match this household account to a bank account first" unless observation
          raise ArgumentError, "Restore this account before reconciling it" unless account.active?
          raise ArgumentError, "Sync or reconnect that bank account before reconciling it" unless observation.fetch("active") && observation.fetch("item_status") == "active"
          raise ArgumentError, "The current bank balance is unavailable" if input[:decision] == "accept_observed" && observation["current_balance_cents"].nil?
          if input[:decision] == "accept_observed" && observation["current_balance_cents"].to_i.negative? && !account.account_type.in?(::Account::SIGNED_BALANCE_TYPES)
            raise ArgumentError, "Only checking or savings can accept a negative bank balance"
          end
          raise ArgumentError, "Sync the bank account before reconciling it" if observation["last_synced_at"].blank?
        end

        def mutate!(account, input, prepared:)
          observation = prepared.before_snapshot.fetch("plaid_observation")
          attrs = { plaid_reconciled_at: Time.iso8601(observation.fetch("last_synced_at")) }
          if input[:decision] == "accept_observed"
            attrs.merge!(balance_cents: observation.fetch("current_balance_cents"), balance_known: true,
              balance_as_of_on: Date.iso8601(observation.fetch("last_synced_at").first(10)), source_type: "plaid")
          end
          account.update!(attrs)
          account
        end

        def canonical_after_snapshot(account, _input, prepared:) = account_snapshot(account.reload)
        def verify_after!(predicted, actual) = verify_account_prediction!(predicted, actual)
      end
    end
  end
end
