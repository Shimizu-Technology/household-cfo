module HouseholdFinance
  class PendingDraftAnswerer
    PENDING_TERMS = /\b(?:pending\s+drafts?|drafts?\s+(?:waiting|pending|review)|waiting\s+(?:for\s+)?(?:approval|review)|pretend\s+pending|what(?:'s|\s+is)\s+pending|(?:did|does|will)\s+(?:that|this|it)\s+count\s+as\s+actuals?|actually\s+ignore\s+(?:that|this|it)|ignore\s+all|ignore\s+(?:that|this|it))\b/i.freeze
    GUARDRAIL_TERMS = /\b(?:pretend\s+pending|ignore\s+all|(?:did|does|will)\s+(?:that|this|it)\s+count\s+as\s+actuals?|actually\s+ignore\s+(?:that|this|it)|ignore\s+(?:that|this|it))\b/i.freeze

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
        return "No pending transaction drafts are waiting right now. Based on confirmed transactions only, nothing pending is counted as actuals. Next CFO move: keep logging spending before it turns into a mystery, then confirm only the drafts that match real money movement."
      end

      total_cents = drafts.sum(&:total_amount_cents)
      preview = drafts.first(5).map do |draft|
        category = draft.budget_category&.name || "Uncategorized"
        "#{draft.merchant} #{money(draft.total_amount_cents)} in #{category}"
      end.to_sentence
      more_line = drafts.length > 5 ? " There are #{drafts.length - 5} more pending drafts after those." : ""
      prefix = if message.match?(/pretend\s+pending/i)
        "No — I will not pretend pending drafts are confirmed actuals."
      elsif message.match?(/ignore\s+all/i)
        "I cannot bulk-ignore every pending draft from chat."
      elsif message.match?(/ignore\s+(?:that|this|it)/i)
        "I cannot ignore a draft from chat; no actuals changed from that request."
      elsif message.match?(/counted|count\s+as\s+actuals?|actuals?/i)
        "No — pending drafts are not counted in actuals."
      else
        "You have #{drafts.length} pending transaction #{'draft'.pluralize(drafts.length)} waiting for review."
      end

      "#{prefix} Pending drafts total #{money(total_cents)} and are not counted as actuals until you confirm them. Waiting for review: #{preview}.#{more_line} Next CFO move: approve only the drafts where merchant, amount, date, and category are right; ignore or correct the rest before using the report as truth."
    end

    private

    attr_reader :household, :message, :today

    def pending_drafts
      @pending_drafts ||= household.transaction_drafts.pending.includes(:budget_category).where(occurred_on: today.beginning_of_year..today.end_of_year).recent_first.to_a
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents.to_i % 100 == 0 ? 0 : 2)
    end
  end
end
