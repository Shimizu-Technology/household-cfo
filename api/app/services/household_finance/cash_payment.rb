module HouseholdFinance
  # A purchase she paid in cash, and her answer to "Paid with the $100 you took out on Aug 3?".
  #
  # Cash counts when it is withdrawn (Leon, 2026-11-19, decision 3): an approved ATM or branch withdrawal is spending in
  # her Cash category. A later purchase paid in cash names part of that cash and adds nothing (CashDrawdowns). This
  # records only what she or her receipt said: a receipt's own payment lines (ReceiptTenders), her "Paid with cash"
  # choice on the form or the purchase card, or her own words to Mia. Cash is never guessed from nothing.
  #
  # draft_payload["cash_payment"] = { "source" => "receipt" | "participant", "cash_cents" => receipt cash (receipt only),
  #   "answer" => nil | "elsewhere" | "withdrawal", "withdrawal_event_id" => the withdrawal she chose (with "withdrawal") }.
  # "elsewhere" is her "No": the cash came from somewhere else, so it counts on its own. "withdrawal" is her "Yes",
  # kept while the purchase is asked "Same purchase?" too, so she answers each question once.
  module CashPayment
    PAYLOAD_KEY = "cash_payment".freeze
    ELSEWHERE = "elsewhere".freeze
    WITHDRAWAL = "withdrawal".freeze
    SOURCES = %w[receipt participant].freeze
    NOT_CASH = /(?:\bcash\s*(?:-\s*)?(?:back|app|card)\b|\bapple\s*cash\b)/i
    # "paid with cash", "paid $40 cash", "in cash", "with cash", "cash purchase". Not cash back, Cash App or Apple Cash.
    SAID = /\b(?:paid|pay|paying|used|using)\s+(?:(?:in|with|by|using)\s+)?(?:\$?\d[\d,]*(?:\.\d{1,2})?\s+(?:in\s+)?)?cash\b|\b(?:in|with|by)\s+cash\b|\bcash\s+(?:purchase|payment)\b/i
    MONEY = /\$\s?\d|\b\d+(?:\.\d{2})\b/

    module_function

    def payload(draft) = (value = draft.draft_payload.to_h[PAYLOAD_KEY]).is_a?(Hash) && value["source"].in?(SOURCES) ? value : nil

    def paid_in_cash?(draft) = payload(draft).present?

    # She said cash for this one purchase. A message naming more than one amount can't say which purchase was cash.
    def said?(text)
      text = text.to_s.unicode_normalize(:nfkc).squish
      return false if text.blank? || text.scan(MONEY).length > 1 || text.match?(/\b(?:not|never)\s+(?:(?:paid|pay|paying)\s+)?(?:(?:in|with|by)\s+)?cash\b/i)

      text.gsub(NOT_CASH, " ").match?(SAID)
    rescue ArgumentError, Encoding::CompatibilityError
      false
    end

    # How much of this purchase was cash, as it would count now.
    def cash_cents(draft, total_cents: draft.total_amount_cents)
      value = payload(draft)
      return 0 unless value
      return total_cents.to_i if value["source"] == "participant"

      [ value["cash_cents"].to_i, total_cents.to_i ].min.clamp(0, nil)
    end

    def receipt_payload(cash_cents) = { "source" => "receipt", "cash_cents" => cash_cents }
    def participant_payload = { "source" => "participant" }

    # She said it was (or wasn't) cash on the form or the purchase card. Her answer to the withdrawal question is
    # asked again after this, since the amount of cash may have changed.
    def with_paid_in_cash(draft_payload, paid)
      payload = draft_payload.to_h.except(PAYLOAD_KEY)
      return payload unless paid

      existing = draft_payload.to_h[PAYLOAD_KEY]
      payload.merge(PAYLOAD_KEY => existing.is_a?(Hash) && existing["source"] == "receipt" ? existing.except("answer") : participant_payload)
    end

    # answer: ELSEWHERE, a withdrawal's event id (her Yes), or nil to forget her answer.
    def with_answer(draft_payload, answer)
      value = draft_payload.to_h[PAYLOAD_KEY]
      return draft_payload.to_h unless value.is_a?(Hash)

      value = value.except("answer", "withdrawal_event_id")
      value = value.merge("answer" => ELSEWHERE) if answer == ELSEWHERE
      value = value.merge("answer" => WITHDRAWAL, "withdrawal_event_id" => answer.to_i) if answer.is_a?(Integer) && answer.positive?
      draft_payload.to_h.merge(PAYLOAD_KEY => value)
    end

    # She said a card line on her statement is this purchase ("Same purchase", ConfirmedPurchaseMatch): it went on her
    # card, so it wasn't cash. Its link to a withdrawal goes, so the purchase counts once on its own and that cash is
    # whole again. Her original cash declaration survives; only this active card match answers it. Runs in the same save.
    def paid_by_card!(household, transaction, version:, user: nil)
      transaction.lock!
      drafts = household.transaction_drafts.where(confirmed_transaction_id: transaction.id).order(:id).lock.select { |draft| paid_in_cash?(draft) }
      link = transaction.metadata.to_h[CashDrawdowns::LINK_KEY]
      return if drafts.empty? && link.nil?

      said = drafts.map { |draft| payload(draft) }
      drafts.each { |draft| draft.update!(draft_payload: with_answer(draft.draft_payload, nil)) }
      transaction.update!(metadata: transaction.metadata.to_h.except(CashDrawdowns::LINK_KEY)) if link
      head = version.source_review_head
      previous = transaction.metadata.to_h.dig("paid_by_card", "previous_link")
      transaction.update!(metadata: transaction.metadata.to_h.merge("paid_by_card" => {
        "source_review_head_id" => head.id, "financial_source_event_id" => head.financial_source_event_id,
        "at" => Time.current.iso8601, "previous_link" => link || previous
      }))
      household.household_audit_events.create!(
        user: user, actor_type: "user", event_type: "cash_purchase.paid_by_card",
        auditable_type: "HouseholdTransaction", auditable_id: transaction.id, occurred_at: Time.current,
        metadata: { source_review_version_id: version.id, cash_withdrawal: link, transaction_draft_ids: drafts.map(&:id), cash_payment: said }.compact
      )
    end

    # The withdrawal she said paid for this pending purchase, if she said so before it could be confirmed.
    def chosen_withdrawal_id(draft)
      value = payload(draft)
      id = value && value["answer"] == WITHDRAWAL ? value["withdrawal_event_id"].to_i : 0
      id.positive? ? id : nil
    end

    # What the purchase card shows. Pending: the withdrawals she can choose from, or that none has cash left.
    # Confirmed: which withdrawal it was paid from, if any.
    def presentation(draft, drawdowns: nil)
      value = payload(draft)
      return nil unless value

      drawdowns ||= CashDrawdowns.new(draft.household)
      return nil if !draft.pending? && drawdowns.card_answered?(draft.confirmed_transaction)

      cents = cash_cents(draft)
      base = { source: value["source"], cash: Money.dollars(cents), cash_cents: cents, answer: value["answer"] }
      if draft.pending?
        return base.merge(candidates: [], message: "You said the cash came from somewhere else, so it counts as its own purchase.") if value["answer"] == ELSEWHERE

        drawdowns ||= CashDrawdowns.new(draft.household)
        chosen = chosen_withdrawal_id(draft) && drawdowns.candidate(chosen_withdrawal_id(draft), on: draft.occurred_on)
        if chosen
          return base.merge(candidates: [], chosen_event_id: chosen.withdrawal.financial_source_event_id,
            message: if chosen.available_cents < cents
              "You said this was paid with #{candidate_label(chosen)}. #{money(chosen.available_cents)} already counted; the other #{money(cents - chosen.available_cents)} still counts on its own."
                     else
              "You said this was paid with #{candidate_label(chosen)}, so it won't add to your spending."
                     end)
        end
        candidates = cents.positive? ? drawdowns.candidates(on: draft.occurred_on) : []
        return base.merge(candidates: [], message: none_message(draft)) if candidates.empty?

        base.merge(candidates: candidates.map { |candidate| candidate_payload(candidate, cents) }, question: question(candidates, cents))
      else
        transaction = draft.confirmed_transaction
        drawdowns ||= CashDrawdowns.new(draft.household)
        if (open = drawdowns.open_question_for(draft))
          return base.merge(linked: false, open_question: open_question_payload(open))
        end
        drawdown = transaction && drawdowns.for_purchase(transaction)
        return base.merge(linked: false) unless drawdown

        base.merge(linked: true, withdrawn_on: drawdown.withdrawn_on.iso8601, linked_cents: drawdown.amount_cents,
          message: "Paid with #{money(drawdown.amount_cents)} of the #{money(drawdown.withdrawal.total_amount_cents)} you took out on #{short_date(drawdown.withdrawn_on)}. It doesn't add to your spending: that cash already counted when you took it out.")
      end
    end

    # A confirmed cash purchase that needs her answer (CashDrawdowns#open_questions): what counts right now, and the
    # question. Until she answers, the part no withdrawal covers counts on its own, on top of the cash she took out.
    def open_question_payload(open)
      draft = open.draft
      purchase = open.purchase
      candidates = open.state == :short ? open.candidates.reject { |row| row.withdrawal.financial_source_event_id == link_event_id(purchase) } : open.candidates
      when_taken = open.link_withdrawn_on ? " on #{short_date(open.link_withdrawn_on)}" : ""
      message = case open.state
      when :unanswered
        "You paid #{money(open.cash_cents)} in cash. Right now it counts on its own, on top of #{candidates.one? ? candidate_label(candidates.first) : 'the cash you took out before it'}."
      when :dropped
        "You said this was paid with cash you took out#{when_taken}, but that withdrawal is no longer in your approved statements. Right now this #{money(open.cash_cents)} counts on its own."
      else
        "The cash you took out#{when_taken} now covers #{money(open.covered_cents)} of this #{money(open.cash_cents)}. Right now the other #{money(open.own_cents)} counts on its own."
      end
      question = if candidates.empty? then nil
      elsif candidates.one? then "Paid with #{candidate_label(candidates.first)}#{open.state == :unanswered ? '' : ' instead'}?"
      else "Which cash paid for this #{money(open.cash_cents)}?"
      end
      {
        transaction_draft_id: draft.id, transaction_id: purchase.id, state: open.state.to_s,
        merchant: purchase.merchant, occurred_on: purchase.occurred_on.iso8601,
        amount: Money.dollars(purchase.total_amount_cents), amount_cents: purchase.total_amount_cents,
        cash_cents: open.cash_cents, covered_cents: open.covered_cents, counting_on_its_own_cents: open.own_cents,
        message: message, question: question,
        candidates: candidates.map { |candidate| candidate_payload(candidate, open.cash_cents) },
        decline_label: open.state == :short ? "Count the rest on its own" : candidates.empty? ? "Count it on its own" : "No, other cash"
      }
    end

    def link_event_id(purchase)
      value = purchase.metadata.to_h.dig(CashDrawdowns::LINK_KEY, "financial_source_event_id").to_i
      value.positive? ? value : nil
    end

    def candidate_payload(candidate, cents)
      withdrawal = candidate.withdrawal
      {
        financial_source_event_id: withdrawal.financial_source_event_id,
        withdrawn_on: withdrawal.occurred_on.iso8601,
        amount: Money.dollars(withdrawal.total_amount_cents),
        amount_cents: withdrawal.total_amount_cents,
        available: Money.dollars(candidate.available_cents),
        available_cents: candidate.available_cents,
        covers_cents: [ cents, candidate.available_cents ].min,
        label: candidate_label(candidate)
      }
    end

    def question(candidates, cents)
      return "Paid with #{candidate_label(candidates.first)}?" if candidates.one?

      "Which cash paid for this #{money(cents)}?"
    end

    def candidate_label(candidate)
      withdrawal = candidate.withdrawal
      label = "the #{money(withdrawal.total_amount_cents)} you took out on #{short_date(withdrawal.occurred_on)}"
      candidate.available_cents < withdrawal.total_amount_cents ? "#{label} (#{money(candidate.available_cents)} left)" : label
    end

    def none_message(draft)
      "Paid with cash. No cash you took out by #{short_date(draft.occurred_on)} has any left in your approved statements, so this counts as its own purchase."
    end

    def short_date(date, today = Date.current)
      date.year == today.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y")
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end
  end
end
