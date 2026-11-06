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

    # A future payoff describes how an existing card would be used; it is not
    # a separate request to compare buying with paying down existing debt.
    CARD_REPAYMENT = /\b(?:and\s+)?pay\s+(?:it|(?:off\s+)?(?:the|that|its)\s+(?:balance|card|statement))\s+(?:off\s+)?(?:in full\s+)?(?:next month|this month)\b/i.freeze

    def self.debt_question?(text)
      return true if text.to_s.match?(/\b(?:credit card|loan|debt)\s+(?:minimum\s+)?payments?\b|\bpayments?\s+(?:on|towards?|for)\s+(?:(?:my|our|the)\s+)?(?:credit card|loan|debt)\b/i)

      text = text.to_s.gsub(CARD_REPAYMENT, "").gsub(/\b(?:on|using|with)\s+(?:(?:my|our|the|a)\s+)?(?:credit )?card\b/i, "")
      text.match?(/\bpay(?:ing)?\s+(?:off|down)\b|\b(?:get|take|borrow|apply for)\b[^.!?]{0,25}\b(?:loan|credit card)\b/i)
    end

    def self.item_label(message)
      text = purchase_clause(message)
      tail = text[/\$\s*[\d,.]+(?:k\b)?\s+(?:for\s+)?(.+)/i, 1] || text[/\b(?:buy|purchase|afford|get|book|order)\s+(.+)/i, 1]
      label = clean_item(tail)
        .sub(/\A(?:a|an|the|this)\s+/i, "").sub(/\Apair of\s+/i, "").strip
      return "" if label.blank? || label.match?(/\A(?:on|for|it|this|that|help|smaller goal|my streak|help|less|credit card|loan)\b/i)

      label.casecmp?("tv") ? "TV" : label.downcase
    end

    def self.clean_item(value)
      value.to_s.split(/[?.!;,]|\s+(?:or|on|using|for|with|from|at|next|this month|today|tomorrow|but|because|and|to|paid|paying)\b/i).first.to_s
    end

    def self.priced_item(label, amount_cents)
      item = clean_item(label).strip.sub(/\A(?:a|an|the|this|pair of)\s+/i, "")
      item = "purchase" if item.blank?
      item = item.downcase unless item == item.upcase
      # Inflect the head noun, not a trailing purpose/payment clause.
      head = item.split.last.to_s
      plural = head.singularize != head
      digits = amount_cents.div(100).to_s
      leading = digits[0, ((digits.length - 1) % 3) + 1].to_i
      article = ([ 8, 11, 18 ].include?(leading) || (80..89).cover?(leading) || (800..899).cover?(leading)) ? "an" : "a"
      price = ActionController::Base.helpers.number_to_currency(Money.dollars(amount_cents), precision: amount_cents % 100 == 0 ? 0 : 2)
      plural ? "#{price} #{item}" : "#{article} #{price} #{item}"
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

    def self.price_reference_only?(segment, first)
      first.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN).one? &&
        !segment.match?(Money::CHAT_DOLLAR_AMOUNT_PATTERN) &&
        segment.match?(/\b(?:that|this|the same)\s+price\b|\bthat (?:is|was|['’]s) the price\b/i) &&
        !segment.match?(/\b(?:instead|actually|changed|different|negotiable|another|new)\b/i)
    end

    def self.for_comparison(message)
      text = purchase_clause(message)
      text = text.split(" Current follow-up: ", 2).last if text.start_with?("Follow-up to previous ")
      segments = text.split(/(?<=[?!])\s+/)
      first = segments.first.to_s
      corrections = segments.drop(1).select { |segment| segment.match?(CORRECTION) }
      unparsed_price = (segments.drop(1) - corrections).any? do |segment|
        !segment.end_with?("?") && !price_reference_only?(segment, first) && (segment.match?(/\b(?:costs?|price|quoted|i meant)\b/i) ||
          (segment.match?(/\A\$\s*\d/) && !segment.match?(/\A\$\s*[\d,.]+(?:k)?\s+of\s+that\b/i)))
      end
      return Result.new(first, unparsed_price) if corrections.empty? || unparsed_price

      amounts = corrections.last.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN)
      return Result.new(first, true) unless amounts.one? && first.scan(Money::CHAT_DOLLAR_AMOUNT_PATTERN).one? && Money.chat_cents(amounts.first.first).positive?

      Result.new(first.sub(Money::CHAT_DOLLAR_AMOUNT_PATTERN, "$#{amounts.first.first}"), false)
    end
  end
end
