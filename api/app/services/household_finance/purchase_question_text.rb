module HouseholdFinance
  # Resolve a correction in the same turn before any purchase comparison.
  module PurchaseQuestionText
    Result = Data.define(:text, :needs_clarification)
    CORRECTION = /\A(?:(?:no|actually|sorry|correction|wait)[,:;]?\s+)*(?:(?:it|the (?:price|cost))\s+(?:actually\s+)?(?:is|costs?)\b|i meant\b|make (?:it|that)\b|\$\s*[\d,.]+(?:k|\s+dollars?)?(?:,?\s+please)?[.!]?\s*\z)/i.freeze

    INCOME_TOPIC = /\b(?:raise|income|salary|make|earn|take home|bring home)\b/i.freeze
    PURCHASE_QUESTION = /\b(?:can|could|should|may)\s+(?:i|we)\b[^?!;]*\b(?:buy|purchase|afford|get|spend|book|order)\b/i.freeze

    def self.income_with_purchase?(message)
      text = message.to_s
      question = text.match(PURCHASE_QUESTION)
      question && text[0...question.begin(0)].match?(INCOME_TOPIC) &&
        !text.match?(/\b(?:set|change|update|create|add|record|schedule|log)\b/i)
    end

    def self.purchase_clause(message)
      text = message.to_s
      income_with_purchase?(text) ? text[text.match(PURCHASE_QUESTION).begin(0)..] : text
    end

    def self.for_comparison(message)
      text = purchase_clause(message)
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
