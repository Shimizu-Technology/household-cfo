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

          matched_transaction = accepted_match.household_transaction
          matched_transaction.lock!
          raise ArgumentError, "Matched transaction belongs to another household" unless matched_transaction.household_id == draft.household_id
          raise ArgumentError, "Matched transaction is already linked to another draft" if matched_elsewhere?(matched_transaction)

          accepted_match.update!(status: "accepted")
          draft.transaction_draft_matches.where.not(id: accepted_match.id).update_all(status: "rejected", updated_at: Time.current)
          draft.update!(status: "matched", matched_transaction: matched_transaction)
        end
        HouseholdFinance::DocumentImportStatusReconciler.new(draft.financial_document_import).call if draft.financial_document_import
      end
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

    def matched_elsewhere?(matched_transaction)
      matched_drafts_for_same_import(matched_transaction).exists? ||
        accepted_matches_for_same_import(matched_transaction).exists?
    end

    def matched_drafts_for_same_import(matched_transaction)
      draft.household.transaction_drafts
        .where(matched_transaction: matched_transaction, status: "matched")
        .where(financial_document_import_id: draft.financial_document_import_id)
        .where.not(id: draft.id)
    end

    def accepted_matches_for_same_import(matched_transaction)
      TransactionDraftMatch.accepted
        .joins(:transaction_draft)
        .where(household_transaction: matched_transaction)
        .where(transaction_drafts: {
          household_id: draft.household_id,
          financial_document_import_id: draft.financial_document_import_id
        })
        .where.not(transaction_draft_id: draft.id)
    end
  end
end
