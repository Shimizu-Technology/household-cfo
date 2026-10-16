module HouseholdFinance
  class DocumentImportStatusReconciler
    def initialize(document_import)
      @document_import = document_import
    end

    def call
      return document_import unless document_import
      return document_import if document_import.failed? || document_import.processing? || document_import.status == "uploaded" || document_import.status == "source_deleted"

      document_import.with_lock do
        document_import.reload
        if document_import.failed? || document_import.processing? || document_import.status == "uploaded" || document_import.status == "source_deleted"
          document_import
        else
          status = reconciled_status
          applied_at = status.in?(%w[applied partially_applied]) ? (document_import.applied_at || Time.current) : nil
          attributes = { status: status, applied_at: applied_at }
          attributes[:applied_by_user] = nil if applied_at.nil?
          document_import.update!(attributes)
          document_import
        end
      end
    end

    private

    attr_reader :document_import

    # Only values the participant approved count as applied. Ignoring every
    # value, or a document with nothing to review, finishes as
    # nothing_applied so it never reaches Mia as an approved source.
    def reconciled_status
      any_saved = resolved_items? || resolved_transaction_drafts?
      any_ignored = ignored_items? || ignored_transaction_drafts?
      # Expense confirmation is not approval of all source rows or coverage.
      return any_saved ? "partially_applied" : "needs_review" if document_import.metadata.to_h["source_accounting_review_pending"] == true
      return any_saved ? "partially_applied" : "needs_review" if actionable_items?
      return any_saved ? "partially_applied" : "needs_review" if pending_transaction_drafts?
      return "applied" if any_saved
      return "nothing_applied" if any_ignored
      return "nothing_applied" if completed_without_reviewable_transactions?

      "needs_review"
    end

    def completed_without_reviewable_transactions?
      metadata = document_import.metadata || {}
      metadata["no_reviewable_transactions"] == true &&
        metadata["routing_requires_confirmation"] != true &&
        !document_import.items.exists? &&
        !document_import.transaction_drafts.exists?
    end

    def actionable_items?
      document_import.items.where(ignored: false, applied_at: nil).exists?
    end

    def pending_transaction_drafts?
      document_import.transaction_drafts.pending.exists?
    end

    def resolved_items?
      document_import.items.where.not(applied_at: nil).exists?
    end

    def resolved_transaction_drafts?
      document_import.transaction_drafts.where(status: %w[confirmed corrected matched]).exists?
    end

    def ignored_items?
      document_import.items.where(ignored: true, applied_at: nil).exists?
    end

    def ignored_transaction_drafts?
      document_import.transaction_drafts.where(status: "ignored").exists?
    end
  end
end
