module HouseholdFinance
  # Her answer to "Paid with the $100 you took out on Aug 3?" on a cash purchase she already confirmed
  # (CashDrawdowns#open_questions): she logged it before the statement with the withdrawal was approved, or the
  # withdrawal it named was removed or made smaller since. Until she answers, it counts on its own; it is never linked
  # for her.
  #
  # Yes names that withdrawal's cash (CashDrawdowns.link!), so the purchase adds nothing and its amount moves out of the
  # cash category in the month the cash was taken out. No ("other cash") keeps it counting on its own, on purpose, and
  # it isn't asked again. The purchase stays confirmed either way: nothing else about it changes.
  #
  # Answering is part of confirming the purchase, so it needs the same access as transaction.draft.confirm. It is safe
  # to repeat: an answer that already holds changes nothing.
  class CashQuestionAnswer
    Stale = Class.new(ArgumentError)
    Result = Struct.new(:draft, :transaction, :message, :changed, keyword_init: true)

    def initialize(household, draft, user:, membership: nil)
      @household = household
      @draft = draft
      @user = user
      @membership = membership
    end

    # cash_withdrawal: the withdrawal's event id (Yes) or CashPayment::ELSEWHERE (No).
    def call(cash_withdrawal:)
      ApplicationRecord.transaction do
        household.lock!
        FinancialGenerationGuard.request!(household)
        CohortReleases::OperationAccess.require!(household: household, user: user, key: "transaction.draft.confirm", membership: membership)
        draft.lock!
        transaction = draft.confirmed_transaction
        unless draft.status.in?(%w[confirmed corrected]) && transaction&.status.in?(CashDrawdowns::COUNTED) && CashPayment.paid_in_cash?(draft)
          raise Stale, "That purchase isn't a confirmed cash purchase any more. Nothing changed."
        end

        transaction.lock!
        return Result.new(draft: draft, transaction: transaction, message: answered_message(transaction), changed: false) if already?(transaction, cash_withdrawal)

        open = CashDrawdowns.new(household).open_question_for(draft)
        raise Stale, "That purchase's cash question was already answered. Nothing changed." unless open

        if cash_withdrawal == CashPayment::ELSEWHERE
          # A link to a withdrawal that is gone names nothing; a link that is short keeps the part it still covers.
          transaction.update!(metadata: transaction.metadata.to_h.except(CashDrawdowns::LINK_KEY)) if open.state == :dropped
          if open.state == :short
            link = transaction.metadata.fetch(CashDrawdowns::LINK_KEY).merge("amount_cents" => open.covered_cents)
            transaction.update!(metadata: transaction.metadata.merge(CashDrawdowns::LINK_KEY => link))
          end
          draft.update!(draft_payload: CashPayment.with_answer(draft.draft_payload, CashPayment::ELSEWHERE))
        else
          CashDrawdowns.link!(household, transaction, event_id: cash_withdrawal, cents: open.cash_cents, user: user)
          draft.update!(draft_payload: CashPayment.with_answer(draft.draft_payload, cash_withdrawal.to_i))
        end
        audit!(transaction, open, cash_withdrawal)
        Result.new(draft: draft.reload, transaction: transaction.reload, message: answered_message(transaction), changed: true)
      end
    end

    private

    attr_reader :household, :draft, :user, :membership

    def already?(transaction, cash_withdrawal)
      return CashPayment.payload(draft)["answer"] == CashPayment::ELSEWHERE if cash_withdrawal == CashPayment::ELSEWHERE

      drawdown = CashDrawdowns.new(household).for_purchase(transaction)
      drawdown && drawdown.event_id == cash_withdrawal.to_i && drawdown.amount_cents >= [ transaction.metadata.dig(CashDrawdowns::LINK_KEY, "amount_cents").to_i, CashPayment.cash_cents(draft, total_cents: transaction.total_amount_cents) ].min
    end

    def audit!(transaction, open, cash_withdrawal)
      household.household_audit_events.create!(
        user: user, actor_type: "user", event_type: "cash_purchase.withdrawal_answered",
        auditable_type: "TransactionDraft", auditable_id: draft.id, occurred_at: Time.current,
        metadata: { transaction_id: transaction.id, asked_because: open.state.to_s, cash_cents: open.cash_cents,
                    answer: cash_withdrawal == CashPayment::ELSEWHERE ? "elsewhere" : "withdrawal",
                    financial_source_event_id: (cash_withdrawal.to_i unless cash_withdrawal == CashPayment::ELSEWHERE) }.compact
      )
    end

    def answered_message(transaction)
      drawdown = CashDrawdowns.new(household).for_purchase(transaction)
      total = CashPayment.money(transaction.total_amount_cents)
      return "Saved: #{transaction.merchant} for #{total} was paid with other cash, so it counts as its own purchase." unless drawdown

      categories = household.budget_categories.where(id: drawdown.cash_parts.pluck(:category_id)).pluck(:name).to_sentence.presence || "Cash"
      rest = CashPayment.cash_cents(draft, total_cents: transaction.total_amount_cents) - drawdown.amount_cents
      also = rest.positive? ? " The other #{CashPayment.money(rest)} counts on its own." : ""
      "Saved: #{transaction.merchant} for #{total} was paid with cash you took out on #{CashPayment.short_date(drawdown.withdrawn_on)}. " \
        "That cash already counted, so #{CashPayment.money(drawdown.amount_cents)} moved from #{categories} into this purchase's category.#{also}"
    end
  end
end
