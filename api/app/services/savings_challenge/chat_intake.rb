module SavingsChallenge
  # Conservative convenience input, never an approval or a financial record.
  # Ambiguous amounts/dates and conditional plans remain ordinary conversation.
  #
  # Each savings movement keeps its own single-amount review.
  # Spending becomes a "daily_report" card: one or more purchases, or an
  # explicit no-spend day, that the participant checks and saves themselves.
  class ChatIntake
    MONEY = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![\d.,])#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/.freeze
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
      @intakes = savings_inputs
      report = daily_report
      @intakes << report if report
      @intakes.first
    end

    def intakes
      @intakes || []
    end

    private

    def savings_inputs
      SavingsReportText.movements(@message).filter_map do |movement|
        next if HouseholdFinance::MoneyMovementText.investment_purchase?(movement[:clause])
        date = requested_date(movement[:clause]) || requested_date(@message)
        next unless date && date.between?(@enrollment.starts_on, [ @enrollment.ends_on, @enrollment.local_today ].min)
        cents = movement[:amount_cents]
        common = { kind: movement[:kind], amount_cents: cents, effective_on: date.iso8601,
          approval_state: "unreviewed_input", counted: false }
        if movement[:kind] == "withdrawal"
          common.merge(signed_cents: -cents)
        else
          common.merge(signed_cents: cents, new_money_confirmation_required: true)
        end
      end
    end

    def daily_report
      purchase_message = SavingsReportText.purchase_text(@message)
      return if purchase_message.blank?
      if !purchase_message.match?(/\b(?:today|yesterday|\d{4}-\d{2}-\d{2})\b/i) && (date = requested_date(@message))
        purchase_message = "#{purchase_message} on #{date.iso8601}"
      end
      parsed = DailyReportParser.new(@enrollment, message: purchase_message).call
      return parsed.report if parsed.found?
      # Without an amount or a store this is conversation, not an incomplete report.
      @rejection = parsed.reason if HouseholdFinance::PurchaseReportText.purchase_details?(@message)
      return unless parsed.none? && HouseholdFinance::PurchaseReportText.normalize(purchase_message).match?(/\d/) && (purchase_message.match?(DailyReportParser::SPEND_VERB) || purchase_message.match?(PLACE))

      (@extractor || DailyReportExtractor.new(@enrollment, message: purchase_message)).call
    end

    def requested_date(message)
      exact = message.scan(/\b\d{4}-\d{2}-\d{2}\b/)
      relative = message.scan(/\b(?:today|yesterday)\b/i).map(&:downcase).uniq
      return unless exact.length + relative.length == 1
      return Date.iso8601(exact.sole) if exact.any?
      @enrollment.local_today - (relative.sole.downcase == "yesterday" ? 1 : 0)
    rescue Date::Error
      nil
    end
  end
end
