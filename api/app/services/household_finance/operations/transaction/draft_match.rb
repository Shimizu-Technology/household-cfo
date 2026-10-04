require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftMatch < Base
        KEY = "transaction.draft.match"
        VERSION = 1

        private

        def normalize(input)
          draft = household.transaction_drafts.find(input[:draft_id].to_i)
          require_legacy_draft!(draft)
          match = if input[:match_id].to_i.positive?
            draft.transaction_draft_matches.find_by(id: input[:match_id].to_i)
          elsif draft.matched?
            draft.transaction_draft_matches.accepted.first
          else
            draft.transaction_draft_matches.proposed.best_first.first
          end
          raise ArgumentError, "Transaction match not found" unless match

          { draft_id: draft.id, match_id: match.id, source_type: normalized_source_type(input[:source_type]), year: draft.occurred_on.year }
        end

        def subject_for(input, lock:)
          scope = household.transaction_drafts
          scope = scope.lock if lock
          scope.find(input.fetch(:draft_id))
        end

        def canonical_snapshot(draft, _input, lock:)
          resolution_snapshot(draft, lock: lock)
        end

        def predicted_after(before, input)
          before.deep_symbolize_keys.tap do |snapshot|
            selected = snapshot.fetch(:matches).find { |match| match[:id] == input.fetch(:match_id) }
            snapshot.fetch(:matches).each { |match| match[:status] = match[:id] == input.fetch(:match_id) ? "accepted" : "rejected" }
            snapshot.fetch(:draft)[:status] = "matched"
            snapshot.fetch(:draft)[:matched_transaction_id] = selected&.fetch(:household_transaction_id)
          end
        end

        def validate_execution!(draft, input, prepared:, source:)
          require_legacy_draft!(draft)
          validate_source!(input, source)
          raise ArgumentError, "Transaction draft is not pending" unless draft.pending?
        end

        def mutate!(draft, input, prepared:)
          result = TransactionDraftMatchAccepter.new(draft, match_id: input.fetch(:match_id)).call
          raise ArgumentError, result.errors.to_sentence unless result.success?

          result.draft
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          resolution_snapshot(draft.reload)
        end

        def verify_after!(_predicted, actual)
          snapshot = actual.deep_stringify_keys
          accepted = Array(snapshot["matches"]).select { |match| match["status"] == "accepted" }
          return true if snapshot.dig("draft", "status") == "matched" && accepted.one? && snapshot.dig("draft", "matched_transaction_id") == accepted.first["household_transaction_id"]

          raise ArgumentError, "The transaction match did not match the requested change. Nothing changed."
        end
      end
    end
  end
end
