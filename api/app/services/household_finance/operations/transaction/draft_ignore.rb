require_relative "base"

module HouseholdFinance
  module Operations
    module Transaction
      class DraftIgnore < Base
        KEY = "transaction.draft.ignore"
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
          draft_snapshot(draft, lock: lock)
        end

        def predicted_after(before, _input)
          before.deep_symbolize_keys.tap { |snapshot| snapshot.fetch(:draft)[:status] = "ignored" }
        end

        def validate_execution!(draft, input, prepared:, source:)
          validate_source!(input, source)
          raise ArgumentError, "Transaction draft is not pending" unless draft.pending?
        end

        def mutate!(draft, _input, prepared:)
          draft.update!(status: "ignored")
          DocumentImportStatusReconciler.new(draft.financial_document_import).call if draft.financial_document_import
          draft
        end

        def canonical_after_snapshot(draft, _input, prepared:)
          draft_snapshot(draft.reload)
        end
      end
    end
  end
end
