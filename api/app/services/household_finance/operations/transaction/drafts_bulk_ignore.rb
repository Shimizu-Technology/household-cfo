require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftsBulkIgnore < Base
        KEY = "transaction.drafts.bulk_ignore"
        VERSION = 1

        private

        def normalize(input)
          ids = Array(input[:draft_ids]).map(&:to_i).select(&:positive?).uniq.sort
          raise ArgumentError, "Select at least one pending transaction review" if ids.empty?
          raise ArgumentError, "Select no more than #{TransactionDraftBulkResolver::MAX_DRAFTS} transaction reviews at once" if ids.length > TransactionDraftBulkResolver::MAX_DRAFTS
          { draft_ids: ids, source_type: normalized_source_type(input[:source_type]), year: input[:year].to_i }
        end

        def ensure_plan!(_input)
          true
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          scope = household.transaction_drafts.where(id: input.fetch(:draft_ids)).order(:id)
          scope = scope.lock if lock
          drafts = scope.to_a
          raise ArgumentError, "One or more transaction reviews could not be found" unless drafts.length == input.fetch(:draft_ids).length

          { draft: { id: household.id, status: "household" }, splits: drafts.map { |draft| { id: draft.id, status: draft.status } } }
        end

        def predicted_after(before, _input)
          before.deep_symbolize_keys.tap do |snapshot|
            snapshot.fetch(:splits).each { |draft| draft[:status] = "ignored" }
          end
        end

        def validate_execution!(_subject, input, prepared:, source:)
          validate_source!(input, source)
        end

        def mutate!(_subject, input, prepared:)
          result = TransactionDraftBulkResolver.new(household, draft_ids: input.fetch(:draft_ids), action: "ignore").call
          raise ArgumentError, result.errors.to_sentence unless result.success?

          household
        end

        def canonical_after_snapshot(_subject, input, prepared:)
          canonical_snapshot(household, input, lock: false)
        end

        def comparable_snapshot(value)
          value.deep_stringify_keys
        end
      end
    end
  end
end
