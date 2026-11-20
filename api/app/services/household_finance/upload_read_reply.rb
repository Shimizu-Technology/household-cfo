module HouseholdFinance
  # Acknowledges only facts that were actually read. No provider is needed.
  class UploadReadReply
    def self.call(household, documents)
      return unless documents.one?
      document = documents.first
      return unless document.household_id == household.id && document.status.in?(%w[needs_review partially_applied applied])
      metadata = document.metadata.to_h
      warning = Array(metadata["warnings"]).find { |text| text.start_with?("You described this as", "Your message described this as") }
      if !warning && metadata["routing_requires_confirmation"]
        resolved = (metadata["routing_resolved_kind"].presence || document.document_kind).humanize.downcase
        detected = (metadata["routing_detected_kind"].presence || "another document type").humanize.downcase
        warning = "You described this as #{resolved}, but I detected #{detected}. I kept your description and flagged the routing difference for review."
      end
      if document.document_kind == "statement"
        revision = document.financial_extraction_revisions.order(revision_number: :desc).first
        return unless revision
        plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, revision)
        total = plan.lines.length
        done = plan.lines.count(&:done)
        right = plan.lines.count { |line| line.ready? && !line.done }
        attention = total - right - done
        state = if total.zero?
          "There are no lines to approve. Nothing from this statement counts as spending."
        elsif done == total
          "You already reviewed every line. Approved spending is already in your numbers."
        elsif done.positive?
          "You already reviewed #{done} #{done == 1 ? 'line' : 'lines'}. The remaining lines are waiting for your review. Only approved spending counts in your numbers."
        else
          "The card below is waiting for you to review and approve it. Nothing counts in your spending until you approve it."
        end
        return [ warning, "I read #{total} #{total == 1 ? 'line' : 'lines'} from your statement. #{right} #{right == 1 ? 'looks' : 'look'} right and #{attention} #{attention == 1 ? 'needs' : 'need'} a look. #{state}" ].compact.join(" ")
      end
      return unless document.document_kind == "receipt"
      drafts = document.transaction_drafts.pending.order(:id).limit(2).to_a
      return unless drafts.one?
      draft = drafts.first
      merchant = SpendingPatterns::MerchantName.call(draft.merchant).presence || "a shop whose name I couldn’t read"
      amount = draft.total_amount_cents ? Money.plain(draft.total_amount_cents) : "an amount I couldn’t read"
      date = draft.occurred_on ? "on #{draft.occurred_on.strftime('%b %-d, %Y')}" : "with no readable date"
      # Part paid with a voucher or gift card: the card proposes only the new money, and says so.
      if (payment = ReceiptTenders.presentation(draft))
        return [ warning, "I read a receipt from #{merchant}, #{date}. #{payment[:message]} The purchase card below is waiting for your tap to review and approve it. It won’t count in your spending until you approve it." ].compact.join(" ")
      end
      [ warning, "I read a receipt from #{merchant} for #{amount}, #{date}. The purchase card below is waiting for your tap to review and approve it. It won’t count in your spending until you approve it." ].compact.join(" ")
    end
  end
end
