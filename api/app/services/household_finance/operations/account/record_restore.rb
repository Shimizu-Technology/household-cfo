require_relative "record_update"

module HouseholdFinance
  module Operations
    module Account
      class RecordRestore < RecordUpdate
        KEY = "account.record.restore"

        private

        def normalize(input) = { account_id: Integer(input.fetch(:account_id)) }

        def canonical_snapshot(account, _input, lock:)
          account_snapshot(account).merge(conflicting_account_ids: conflict_ids(label: account.label, account_type: account.account_type, excluding_id: account.id, lock: lock))
        end

        def predicted_after(before, _input)
          { account: before.fetch("account").merge("active" => true, "archived_at" => nil), conflicting_account_ids: before.fetch("conflicting_account_ids") }
        end

        def validate_execution!(account, _input, prepared:, source:)
          raise ArgumentError, "This account is already active. Nothing changed." if account.active?
          raise ArgumentError, "An active account already uses that name and type. Rename it before restoring this record. Nothing changed." if prepared.before_snapshot.fetch("conflicting_account_ids").any?
        end

        def mutate!(account, _input, prepared:)
          account.update!(active: true, archived_at: nil)
          account
        end
      end
    end
  end
end
