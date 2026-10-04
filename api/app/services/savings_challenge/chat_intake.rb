module SavingsChallenge
  # Conservative convenience input, never an approval or a financial record.
  # Ambiguous amounts/dates and conditional plans remain ordinary conversation.
  class ChatIntake
    MONEY = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)(?![\d.,])/.freeze
    def initialize(enrollment, message:) = (@enrollment, @message = enrollment, message.to_s)
    def call
      return unless @enrollment && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      return if @message.match?(/\?|\b(?:if|would|could|might|plan|planning|want to|will|should|haven.t|didn.t|did not|not yet|did not|refund|borrowed|cash advance|credit card payment)\b/i)
      amounts = @message.scan(MONEY).flatten
      return unless amounts.length == 1
      whole, fraction = amounts.sole.delete(",").split(".", 2)
      cents = whole.to_i * 100 + fraction.to_s.ljust(2, "0").to_i
      return unless cents.between?(1, 2_147_483_647)
      date = requested_date
      return unless date && date.between?(@enrollment.starts_on, [ @enrollment.ends_on, @enrollment.local_today ].min)
      common = { amount_cents: cents, effective_on: date.iso8601, approval_state: "unreviewed_input", counted: false }
      if @message.match?(/\b(?:spent|bought|paid)\b/i)
        merchant = @message[/\b(?:at|from)\s+(.+?)(?=\s+(?:today|yesterday|on\s+\d{4}-\d{2}-\d{2})\b|[.!]\z|\z)/i, 1]&.squish
        return unless merchant.present? && merchant.length <= 120 && !merchant.include?("$")
        common.merge(kind: "purchase", merchant: merchant)
      elsif @message.match?(/\b(?:withdrew|withdrawn|took)\b.{0,60}\b(?:savings|reserved|set aside)\b/i)
        common.merge(kind: "withdrawal", signed_cents: -cents)
      elsif @message.match?(/\b(?:set aside|reserved|saved|put aside)\b/i)
        common.merge(kind: "contribution", signed_cents: cents, new_money_confirmation_required: true)
      end
    end

    private
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
