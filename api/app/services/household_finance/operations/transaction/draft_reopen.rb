require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftReopen < Base
        KEY = "transaction.draft.reopen"
        VERSION = 1

        private

        def normalize(input)
          draft = household.transaction_drafts.find(input[:draft_id].to_i)
          { draft_id: draft.id, source_type: normalized_source_type(input[:source_type]), year: draft.occurred_on.year }
        end

        def subject_for(input, lock:)
          scope = household.transaction_drafts
          scope = scope.lock if lock
          scope.find(input.fetch(:draft_id))
        end

        def canonical_snapshot(draft, _input, lock:)
          resolution_snapshot(draft, lock: lock)
        end

        def predicted_after(before, _input)
          before.deep_symbolize_keys.tap do |snapshot|
            snapshot.fetch(:draft)[:status] = "pending"
            snapshot.fetch(:draft)[:confirmed_transaction_id] = nil
            snapshot.fetch(:draft)[:matched_transaction_id] = nil
            snapshot[:transaction][:status] = "ignored" if snapshot[:transaction]
          end
        end

        def validate_execution!(draft, input, prepared:, source:)
          validate_source!(input, source)
          raise ArgumentError, "Transaction draft is already pending" if draft.pending?
        end

        def mutate!(draft, _input, prepared:)
          result = TransactionDraftReopener.new(draft).call
          raise ArgumentError, result.errors.to_sentence unless result.success?

          result.draft
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          resolution_snapshot(draft.reload)
        end

        def verify_after!(_predicted, actual)
          snapshot = actual.deep_stringify_keys
          draft = snapshot.fetch("draft")
          return true if draft["status"] == "pending" && draft["confirmed_transaction_id"].nil? && draft["matched_transaction_id"].nil?

          raise ArgumentError, "The transaction reopen did not match the requested change. Nothing changed."
        end
      end
    end
  end
end
