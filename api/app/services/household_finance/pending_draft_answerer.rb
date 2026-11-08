module HouseholdFinance
  class PendingDraftAnswerer
    PENDING_TERMS = /\b(?:pending\s+drafts?|drafts?\s+(?:waiting|pending|review)|waiting\s+(?:for\s+)?(?:approval|review)|pretend\s+pending|what(?:'s|\s+is)\s+pending|(?:did|does|will)\s+(?:that|this|it)\s+count\s+as\s+actuals?|actually\s+ignore\s+(?:that|this|it)|ignore\s+all|ignore\s+(?:that|this|it))\b/i.freeze
    GUARDRAIL_TERMS = /\b(?:pretend\s+pending|(?:did|does|will)\s+(?:that|this|it)\s+count\s+as\s+actuals?)\b/i.freeze

    def self.guardrail_question?(message)
      message.to_s.match?(GUARDRAIL_TERMS)
    end

    def initialize(household, message, today: Date.current)
      @household = household
      @message = message.to_s
      @today = today
    end

    def call
      return nil unless message.match?(PENDING_TERMS)

      drafts = pending_drafts
      if drafts.empty?
        return "No purchases are waiting for review right now. Keep adding your purchases, then confirm the ones that match what you spent."
      end

      total_cents = drafts.sum(&:total_amount_cents)
      preview = drafts.first(5).map do |draft|
        category = draft.budget_category&.name || "Needs a category"
        "#{draft.merchant} #{money(draft.total_amount_cents)} in #{category}"
      end.to_sentence
      more_line = drafts.length > 5 ? " There are #{drafts.length - 5} more purchases waiting for review after those." : ""
      prefix = if message.match?(/pretend\s+pending/i)
        "No — purchases waiting for review are not counted as spending."
      elsif message.match?(/counted|count\s+as\s+actuals?|actuals?/i)
        "No — purchases waiting for review are not counted as spending."
      else
        "You have #{drafts.length} #{'purchase'.pluralize(drafts.length)} waiting for review."
      end

      "#{prefix} Purchases waiting for review total #{money(total_cents)} and do not count in your spending until you confirm them. Waiting for review: #{preview}.#{more_line} Check the merchant, amount, date, and category; confirm what is right and correct or leave out the rest."
    end

    private

    attr_reader :household, :message, :today

    def pending_drafts
      @pending_drafts ||= household.transaction_drafts.pending.excluding_non_spending_plaid.includes(:budget_category).where(occurred_on: today.beginning_of_year..today.end_of_year).recent_first.to_a
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end
  end
end
