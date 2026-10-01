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
            reopened_from_status = snapshot.fetch(:draft).fetch(:status)
            snapshot[:reopened_from_status] = reopened_from_status
            snapshot.fetch(:draft)[:status] = "pending"
            snapshot.fetch(:draft)[:confirmed_transaction_id] = nil
            snapshot.fetch(:draft)[:matched_transaction_id] = nil
            snapshot[:transaction][:status] = "ignored" if snapshot[:transaction]
            snapshot.fetch(:matches).each { |match| match[:status] = "proposed" } if reopened_from_status == "matched"
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
          reopened_from_status = prepared.before_snapshot.dig("draft", "status")
          prior_transaction_id = prepared.before_snapshot.dig("transaction", "id")
          resolution_snapshot(draft.reload, transaction_id: prior_transaction_id).merge(reopened_from_status: reopened_from_status)
        end

        def verify_after!(predicted, actual)
          expected = predicted.deep_stringify_keys
          snapshot = actual.deep_stringify_keys
          draft = snapshot.fetch("draft")
          valid = draft["status"] == "pending" && draft["confirmed_transaction_id"].nil? && draft["matched_transaction_id"].nil?
          case snapshot.fetch("reopened_from_status")
          when "confirmed", "corrected"
            expected_transaction = expected["transaction"]
            actual_transaction = snapshot["transaction"]
            if expected_transaction.present? && actual_transaction.present?
              valid &&= actual_transaction["status"] == "ignored"
              valid &&= actual_transaction.except("status") == expected_transaction.except("status")
            else
              valid = false
            end
          when "matched"
            expected_match_ids = Array(expected["matches"]).map { |match| match.fetch("id") }
            actual_matches = Array(snapshot["matches"])
            valid &&= actual_matches.none? { |match| match["status"] == "accepted" }
            valid &&= expected_match_ids.all? do |id|
              actual_matches.any? { |match| match["id"] == id && match["status"] == "proposed" }
            end
            valid &&= snapshot["transaction"].nil?
          when "ignored"
            valid &&= snapshot["transaction"].nil?
            valid &&= Array(snapshot["matches"]).none? { |match| match["status"] == "accepted" }
          else
            valid = false
          end
          return true if valid

          raise ArgumentError, "The transaction reopen did not match the requested change. Nothing changed."
        end
      end
    end
  end
end
