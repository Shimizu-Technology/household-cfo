require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      class PlaidUnlink < Base
        KEY = "account.plaid.unlink"
        VERSION = 1

        private

        def normalize(input) = { account_id: Integer(input.fetch(:account_id)) }
        def subject_for(input, lock:) = account_scope(lock: lock).find(input[:account_id])
        def canonical_snapshot(account, _input, lock:) = account_snapshot(account)
        def predicted_after(before, _input) = { account: before.fetch("account").merge("plaid_account_id" => nil) }

        def validate_execution!(account, _input, prepared:, source:)
          raise ArgumentError, "This account is not matched to a bank observation" unless account.plaid_account_id
        end

        def mutate!(account, _input, prepared:)
          account.update!(plaid_account: nil)
          account
        end

        def canonical_after_snapshot(account, _input, prepared:) = account_snapshot(account.reload)
        def verify_after!(predicted, actual) = verify_account_prediction!(predicted, actual)
      end
    end
  end
end
