module HouseholdFinance
  # Resolve a correction in the same turn before any purchase comparison.
  module PurchaseQuestionText
    Result = Data.define(:text, :needs_clarification)
    CORRECTION = /\A(?:(?:no|actually|sorry|correction|wait)[,:;]?\s+)*(?:(?:it|the (?:price|cost))\s+(?:actually\s+)?(?:is|costs?)\b|i meant\b|make (?:it|that)\b|\$\s*[\d,.]+(?:k|\s+dollars?)?(?:,?\s+please)?[.!]?\s*\z)/i.freeze

    def self.for_comparison(message)
      text = message.to_s
      text = text.split(" Current follow-up: ", 2).last if text.start_with?("Follow-up to previous ")
      segments = text.split(/(?<=[?!])\s+/)
      first = segments.first.to_s
      corrections = segments.drop(1).select { |segment| segment.match?(CORRECTION) }
      unparsed_price = (segments.drop(1) - corrections).any? do |segment|
        !segment.end_with?("?") && (segment.match?(/\b(?:costs?|price|i meant)\b/i) ||
          (segment.match?(/\A\$\s*\d/) && !segment.match?(/\A\$\s*[\d,.]+(?:k)?\s+of\s+that\b/i)))
      end
      return Result.new(first, unparsed_price) if corrections.empty? || unparsed_price

      amounts = corrections.last.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN)
      return Result.new(first, true) unless amounts.one? && first.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN).one? && Money.chat_cents(amounts.first.first).positive?

      Result.new(first.sub(Money::CHAT_DOLLAR_AMOUNT_PATTERN, "$#{amounts.first.first}"), false)
    end
  end
end
