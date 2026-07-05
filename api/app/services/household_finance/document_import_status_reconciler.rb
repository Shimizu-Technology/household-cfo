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
          timestamp = Time.current if status.in?(%w[applied partially_applied]) && document_import.applied_at.blank?
          document_import.update!(status: status, applied_at: timestamp || document_import.applied_at)
          document_import
        end
      end
    end

    private

    attr_reader :document_import

    def reconciled_status
      any_resolved = resolved_items? || ignored_items? || resolved_transaction_drafts? || ignored_transaction_drafts?
      return any_resolved ? "partially_applied" : "needs_review" if actionable_items?
      return any_resolved ? "partially_applied" : "needs_review" if pending_transaction_drafts?
      return "applied" if any_resolved

      "needs_review"
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
