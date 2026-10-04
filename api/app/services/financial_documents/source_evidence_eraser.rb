# frozen_string_literal: true

module FinancialDocuments
  class SourceEvidenceEraser
    def self.call(document_import)
      return unless document_import.persisted?

      revisions = document_import.financial_extraction_revisions.select(:id)
      accounts = FinancialSourceAccount.where(financial_extraction_revision_id: revisions).select(:id)
      events = FinancialSourceEvent.where(financial_extraction_revision_id: revisions).select(:id)
      FinancialSourceEvidence.where(financial_source_account_id: accounts)
        .or(FinancialSourceEvidence.where(financial_source_event_id: events)).delete_all
      # Source evidence is disposable. Confirmed financial facts retain their
      # own participant-approved fields and the immutable source lineage.
      document_import.transaction_drafts.update_all(raw_input: nil, draft_payload: {}, updated_at: Time.current)
      unapproved = document_import.transaction_drafts.where(status: %w[pending ignored])
      unapproved.update_all(merchant: "Source row", updated_at: Time.current)
      TransactionDraftSplit.where(transaction_draft_id: unapproved.select(:id)).update_all(notes: nil, metadata: {}, updated_at: Time.current)
      document_import.items.update_all(evidence: nil, metadata: {}, updated_at: Time.current)
      document_import.update_columns(extracted_summary: nil, extraction_error: nil,
        metadata: document_import.metadata.to_h.except("warnings"))
    end
  end
end
