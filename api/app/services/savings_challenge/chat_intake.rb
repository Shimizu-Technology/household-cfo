module SavingsChallenge
  # Conservative convenience input, never an approval or a financial record.
  # Ambiguous amounts/dates and conditional plans remain ordinary conversation.
  #
  # Savings contributions and withdrawals keep their single-amount review.
  # Spending becomes a "daily_report" card: one or more purchases, or an
  # explicit no-spend day, that the participant checks and saves themselves.
  class ChatIntake
    MONEY = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![\d.,])#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/.freeze
    SAVINGS_MOVE = /\b(?:withdrew|withdrawn|took)\b.{0,60}\b(?:savings|reserved|set aside)\b|\b(?:set aside|reserved|saved|put aside)\b/i.freeze
    # Money moved into savings is never a purchase, even when it is not a reviewable contribution.
    INTO_SAVINGS = DailyReportParser::INTO_SAVINGS
    # Worth asking the extractor only when it could produce a card: a number, and
    # a spending verb or a place.
    PLACE = /\b(?:at|from)\s+[a-z]/i.freeze

    def initialize(enrollment, message:, extractor: nil)
      @enrollment, @message, @extractor = enrollment, message.to_s, extractor
    end

    # Why a clearly reported day could not become a card (outside the window), or nil.
    attr_reader :rejection

    def call
      return unless @enrollment && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      # Savings wording is read first ("picked up a shift and saved $50 today").
      if savings_report?
        intake = savings_input
        return intake if intake
      end
      return if @message.match?(INTO_SAVINGS)

      daily_report
    end

    private

    def savings_report?
      HouseholdFinance::MoneyMovementText.savings_deposit_report?(@message) || @message.match?(SAVINGS_MOVE)
    end

    def savings_input
      return if @message.match?(/\?|\b(?:if|would|could|might|plan|planning|want to|will|should|haven.t|didn.t|did not|not yet|refund|borrowed|cash advance|credit card payment)\b/i)
      amounts = @message.scan(MONEY).flatten
      return unless amounts.length == 1
      cents = HouseholdFinance::Money.chat_cents(amounts.sole)
      return unless cents.between?(1, 2_147_483_647)
      date = requested_date
      return unless date && date.between?(@enrollment.starts_on, [ @enrollment.ends_on, @enrollment.local_today ].min)
      common = { amount_cents: cents, effective_on: date.iso8601, approval_state: "unreviewed_input", counted: false }
      # Crypto or stock buys are neither a challenge purchase nor saved money.
      return if HouseholdFinance::MoneyMovementText.investment_purchase?(@message)
      if HouseholdFinance::MoneyMovementText.savings_deposit_report?(@message)
        common.merge(kind: "contribution", signed_cents: cents, new_money_confirmation_required: true)
      elsif @message.match?(/\b(?:withdrew|withdrawn|took)\b.{0,60}\b(?:savings|reserved|set aside)\b/i)
        common.merge(kind: "withdrawal", signed_cents: -cents)
      elsif @message.match?(/\b(?:set aside|reserved|saved|put aside)\b/i)
        common.merge(kind: "contribution", signed_cents: cents, new_money_confirmation_required: true)
      end
    end

    def daily_report
      parsed = DailyReportParser.new(@enrollment, message: @message).call
      return parsed.report if parsed.found?
      @rejection = parsed.reason
      return unless parsed.none? && @message.match?(/\d/) && (@message.match?(DailyReportParser::SPEND_VERB) || @message.match?(PLACE))

      (@extractor || DailyReportExtractor.new(@enrollment, message: @message)).call
    end

    def requested_date
      exact = @message.scan(/\b\d{4}-\d{2}-\d{2}\b/)
      relative = @message.scan(/\b(?:today|yesterday)\b/i)
      return unless exact.length + relative.length == 1
      return Date.iso8601(exact.sole) if exact.any?
      @enrollment.local_today - (relative.sole.downcase == "yesterday" ? 1 : 0)
    rescue Date::Error
      nil
    end
  end
end
