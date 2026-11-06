module HouseholdFinance
  # Resolve a correction in the same turn before any purchase comparison.
  module PurchaseQuestionText
    Result = Data.define(:text, :needs_clarification)
    CORRECTION = /\A(?:(?:no|actually|sorry|correction|wait)[,:;]?\s+)*(?:(?:it|the (?:price|cost))\s+(?:actually\s+)?(?:is|costs?)\b|i meant\b|make (?:it|that)\b|\$\s*[\d,.]+(?:k|\s+dollars?)?(?:,?\s+please)?[.!]?\s*\z)/i.freeze

    INCOME_TOPIC = /\b(?:raise|income|salary|earn|take home|bring home)\b|\bmake\s+\$?\d/i.freeze
    PURCHASE_QUESTION = /\b(?:can|could|should|may)\s+(?:i|we)\b[^?!;]*\b(?:buy|purchase|afford|get|spend|book|order)\b/i.freeze

    def self.income_with_purchase?(message)
      text = message.to_s
      question = text.match(PURCHASE_QUESTION)
      question && text[0...question.begin(0)].match?(INCOME_TOPIC) &&
        !text.match?(/\b(?:set|change|update|create|add|record|schedule|log)\b/i)
    end

    def self.debt_question?(text)
      text.to_s.match?(/\bpay(?:ing)?\s+(?:off|down)\b|\b(?:get|take|borrow|apply for)\b[^.!?]{0,25}\b(?:loan|credit card)\b/i)
    end

    def self.item_label(message)
      text = purchase_clause(message)
      tail = text[/\$\s*[\d,.]+(?:k\b)?\s+(?:for\s+)?(.+)/i, 1] || text[/\b(?:buy|purchase|afford|get|book|order)\s+(.+)/i, 1]
      label = tail.to_s.split(/[?.!;,]|\s+(?:or|on|using|for|with|from|at|next|this month|today|tomorrow|but|because|and)\b/i).first.to_s
        .sub(/\A(?:a|an|the|this)\s+/i, "").sub(/\Apair of\s+/i, "").strip
      return "" if label.blank? || label.match?(/\A(?:on|for|it|this|that|help|smaller goal|my streak|help|less|credit card|loan)\b/i)

      label.casecmp?("tv") ? "TV" : label.downcase
    end

    def self.purchase_question?(message)
      text = message.to_s
      !debt_question?(text) && !text.match?(/\bspend less\b/i) &&
        MiaCoachAnswerer::PURCHASE_INTENT_PATTERNS.any? { |pattern| text.match?(pattern) } && item_label(text).present?
    end

    def self.read_only_purchase_question?(message)
      # A funding description is not an instruction to reserve new money.
      text = message.to_s.gsub(/\b(?:money|funds|cash)\s+(?:already\s+)?set aside\b/i, "reserved money")
      purchase_question?(text) && !MiaCoachAnswerer.explicit_write_request?(text)
    end

    def self.unfunded?(text)
      text.to_s.match?(/\b(?:don['’]?t|do not) have (?:the )?money\b|\b(?:can['’]?t|cannot|won['’]?t|will not)\s+(?:pay|cover|afford)\b/i)
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
