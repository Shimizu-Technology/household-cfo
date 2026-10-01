require_relative "record_update"

module HouseholdFinance
  module Operations
    module Account
      class RecordArchive < RecordUpdate
        KEY = "account.record.archive"

        private

        def normalize(input) = { account_id: Integer(input.fetch(:account_id)) }
        def canonical_snapshot(account, _input, lock:) = account_snapshot(account)
        def predicted_after(before, _input) = { account: before.fetch("account").except("archived_at").merge("active" => false) }

        def validate_execution!(account, _input, prepared:, source:)
          raise ArgumentError, "This account is already archived. Nothing changed." unless account.active?
        end

        def mutate!(account, _input, prepared:)
          account.update!(active: false, archived_at: Time.current)
          account
        end
      end
    end
  end
end
