require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      class RecordCreate < Base
        KEY = "account.record.create"
        VERSION = 1

        private

        def normalize(input)
          values = {
            label: normalized_label(input[:label]),
            account_type: normalized_type(input[:account_type].presence || "other"),
            source_type: input[:source_type].to_s.presence_in(::Account::SOURCE_TYPES) || "manual_ui",
            source_metadata: input[:source_metadata].is_a?(Hash) ? input[:source_metadata].slice("document_import_id", "document_import_item_id") : {}
          }.merge(normalize_balance(input, required: true))
          values[:plaid_account_id] = Integer(input[:plaid_account_id]) if input[:plaid_account_id].present?
          values[:source_type] = "plaid" if values[:plaid_account_id] && values[:balance_known]
          validate_balance_type!(values)
          values
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          plaid = input[:plaid_account_id] ? plaid_scope(lock: lock).find(input[:plaid_account_id]) : nil
          {
            account: nil,
            conflicting_account_ids: conflict_ids(label: input[:label], account_type: input[:account_type], lock: lock),
            plaid_observation: plaid_snapshot(plaid)
          }
        end

        def predicted_after(before, input)
          account = input.slice(:label, :account_type, :balance_cents, :balance_known, :balance_as_of_on, :source_type, :source_metadata, :plaid_account_id)
            .merge(active: true, archived_at: nil, plaid_reconciled_at: input[:plaid_account_id] && input[:balance_known] ? before.dig("plaid_observation", "last_synced_at") : nil)
          if input[:plaid_account_id] && input[:balance_known]
            account[:balance_as_of_on] = before.dig("plaid_observation", "last_synced_at").to_s.first(10)
          end
          { account: account, conflicting_account_ids: before.fetch("conflicting_account_ids"), plaid_observation: before["plaid_observation"] }
        end

        def validate_execution!(_household, input, prepared:, source:)
          raise ArgumentError, "An active account already uses that name and type. Nothing changed." if prepared.before_snapshot.fetch("conflicting_account_ids").any?
          validate_plaid!(input, prepared.before_snapshot["plaid_observation"]) if input[:plaid_account_id]
        end

        def mutate!(_household, input, prepared:)
          attrs = input.slice(:label, :account_type, :balance_cents, :balance_known, :balance_as_of_on, :source_type, :source_metadata, :plaid_account_id)
          attrs[:plaid_reconciled_at] = Time.iso8601(prepared.before_snapshot.dig("plaid_observation", "last_synced_at")) if input[:plaid_account_id] && input[:balance_known] && prepared.before_snapshot.dig("plaid_observation", "last_synced_at")
          attrs[:balance_as_of_on] = prepared.before_snapshot.dig("plaid_observation", "last_synced_at").to_s.first(10) if input[:plaid_account_id] && input[:balance_known]
          household.accounts.create!(attrs.merge(active: true, archived_at: nil))
        end

        def canonical_after_snapshot(account, _input, prepared:)
          account_snapshot(account.reload)
        end

        def verify_after!(predicted, actual)
          verify_account_prediction!(predicted, actual)
        end

        def validate_plaid!(input, observation)
          raise ArgumentError, "That bank account is not available to this household" unless observation
          raise ArgumentError, "That bank account cannot be used as an asset" unless observation.fetch("eligible")
          raise ArgumentError, "Sync or reconnect that bank account before using it" unless observation.fetch("active") && observation.fetch("item_status") == "active"
          raise ArgumentError, "That bank account is already matched" if observation["linked_account_id"]
          raise ArgumentError, "Choose a compatible household account type" unless observation.fetch("allowed_account_types").include?(input[:account_type])
          raise ArgumentError, "The current bank balance is unavailable" if input[:balance_known] && observation["current_balance_cents"].nil?
          if input[:balance_known] && input[:balance_cents] != observation["current_balance_cents"]
            raise ArgumentError, "The reviewed bank balance changed. Prepare a fresh review"
          end
        end
      end
    end
  end
end
