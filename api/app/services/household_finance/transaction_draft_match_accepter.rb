module HouseholdFinance
  class TransactionDraftMatchAccepter
    Result = Data.define(:success, :draft, :match, :errors) do
      def success?
        success == true
      end
    end

    def initialize(draft, match_id: nil)
      @draft = draft
      @match_id = match_id
    end

    def call
      accepted_match = nil
      ApplicationRecord.transaction do
        draft.with_lock do
          raise ArgumentError, "Transaction draft is not pending" unless draft.pending?

          accepted_match = selected_match
          raise ArgumentError, "Transaction match not found" unless accepted_match
          raise ArgumentError, "Matched transaction belongs to another household" unless accepted_match.household_transaction.household_id == draft.household_id

          accepted_match.update!(status: "accepted")
          draft.transaction_draft_matches.where.not(id: accepted_match.id).update_all(status: "rejected", updated_at: Time.current)
          draft.update!(status: "matched", matched_transaction: accepted_match.household_transaction)
        end
      end
      HouseholdFinance::DocumentImportStatusReconciler.new(draft.financial_document_import).call if draft.financial_document_import
      Result.new(success: true, draft: draft.reload, match: accepted_match.reload, errors: [])
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Result.new(success: false, draft: draft.reload, match: nil, errors: [ e.message ])
    end

    private

    attr_reader :draft, :match_id

    def selected_match
      scope = draft.transaction_draft_matches.proposed.best_first
      match_id.present? ? scope.find_by(id: match_id) : scope.first
    end
  end
end
