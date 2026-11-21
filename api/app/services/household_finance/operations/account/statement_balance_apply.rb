require_relative "base"

module HouseholdFinance
  module Operations
    module Account
      # Sets an account's balance to the closing balance on its latest approved
      # statement, with that statement's end date as the balance date. With
      # new_account, adds the account to My Money with that balance instead.
      class StatementBalanceApply < Base
        include Operations::StatementBalance

        KEY = "account.statement_balance.apply"
        VERSION = 1

        private

        def normalize(input) = normalize_offer_input(input, id_key: :account_id, new_key: :new_account)

        def subject_for(input, lock:)
          return account_scope(lock: lock).find(input[:account_id]) if input[:account_id]

          lock ? household.lock! : household
        end

        def canonical_snapshot(subject, input, lock:)
          offer = current_offer(input)
          conflicts = if input[:new_account] && offer&.fetch("new_label", nil)
            conflict_ids(label: offer.fetch("new_label"), account_type: new_type(offer, input), lock: lock)
          else
            []
          end
          { account: subject.is_a?(::Account) ? account_snapshot(subject).fetch(:account) : nil, offer: offer, conflicting_account_ids: conflicts }
        end

        def predicted_after(before, input)
          offer = reviewed_offer!(before, input, "account")
          base = before["account"] || { "label" => offer["new_label"], "account_type" => new_type(offer, input), "active" => true,
            "archived_at" => nil, "plaid_account_id" => nil, "plaid_reconciled_at" => nil }
          account = base.merge("balance_cents" => offer.fetch("balance_cents"), "balance_known" => true, "balance_as_of_on" => offer.fetch("as_of_on"),
            "source_type" => "document_import", "source_metadata" => statement_metadata(base["source_metadata"], offer))
          { account: account }
        end

        def validate_execution!(subject, input, prepared:, source:)
          offer = reviewed_offer!(prepared.before_snapshot, input, "account")
          if input[:account_id]
            raise ArgumentError, "Restore this account before updating it. Nothing changed." unless subject.active?
            chosen_target!(offer, subject.id)
          else
            raise Operations::Base::StaleOperation, stale_message unless offer["can_add_new"] && offer["new_label"].present?
            raise ArgumentError, "An active account already uses that name and type. Nothing changed." if prepared.before_snapshot.fetch("conflicting_account_ids").any?
          end
          validate_balance_type!(prepared.predicted_after_snapshot.fetch("account").symbolize_keys)
        end

        def mutate!(subject, input, prepared:)
          after = prepared.predicted_after_snapshot.fetch("account")
          attrs = { balance_cents: after.fetch("balance_cents"), balance_known: true, balance_as_of_on: Date.iso8601(after.fetch("balance_as_of_on")),
            source_type: "document_import", source_metadata: after.fetch("source_metadata") }
          return subject.tap { |account| account.update!(attrs) } if input[:account_id]

          household.accounts.create!(attrs.merge(label: after.fetch("label"), account_type: after.fetch("account_type"), active: true, archived_at: nil))
        end

        def canonical_after_snapshot(account, _input, prepared:) = account_snapshot(account.reload)
        def verify_after!(predicted, actual) = verify_account_prediction!(predicted, actual)
      end
    end
  end
end
