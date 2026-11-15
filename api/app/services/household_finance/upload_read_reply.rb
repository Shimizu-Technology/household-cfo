module HouseholdFinance
  # Acknowledges only facts that were actually read. No provider is needed.
  class UploadReadReply
    def self.call(household, documents)
      return unless documents.one?
      document = documents.first
      return unless document.household_id == household.id && document.status.in?(%w[needs_review partially_applied applied])
      if document.document_kind == "statement"
        revision = document.financial_extraction_revisions.order(revision_number: :desc).first
        return unless revision
        plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, revision)
        total = plan.lines.length
        right = plan.lines.count { |line| line.ready? || line.done }
        attention = total - right
        return "I read #{total} #{total == 1 ? 'line' : 'lines'} from your statement. #{right} #{right == 1 ? 'looks' : 'look'} right and #{attention} #{attention == 1 ? 'needs' : 'need'} a look. The card below is waiting for you to review and approve it. Nothing counts in your spending until you approve it."
      end
      return unless document.document_kind == "receipt"
      drafts = document.transaction_drafts.pending.order(:id).limit(2).to_a
      return unless drafts.one?
      draft = drafts.first
      merchant = FinancialDocuments::AccountNumberMask.display(draft.merchant).presence || "a shop whose name I couldn’t read"
      amount = draft.total_amount_cents ? Money.plain(draft.total_amount_cents) : "an amount I couldn’t read"
      date = draft.occurred_on ? "on #{draft.occurred_on.strftime('%b %-d, %Y')}" : "with no readable date"
      "I read a receipt from #{merchant} for #{amount}, #{date}. The purchase card below is waiting for your tap to review and approve it. It won’t count in your spending until you approve it."
    end
  end
end
