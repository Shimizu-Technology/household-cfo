module HouseholdFinance
  # Resolve a correction in the same turn before any purchase comparison.
  module PurchaseQuestionText
    Result = Data.define(:text, :needs_clarification)
    CORRECTION = /\A(?:(?:no|actually|sorry|correction|wait)[,:;]?\s+)*(?:(?:it|the (?:price|cost))\s+(?:actually\s+)?(?:is|costs?)\b|i meant\b|make (?:it|that)\b|\$\s*[\d,.]+(?:k|\s+dollars?)?(?:,?\s+please)?[.!]?\s*\z)/i.freeze

    INCOME_TOPIC = /\b(?:raise|income|salary|earn|take home|bring home)\b|\bmake\s+\$?\d/i.freeze
    MONTHLY_INCOME = /\b(?:get(?:s)?\s+paid|my\s+check|pay\s*checks?|wages?|pay\s+is)\b/i.freeze
    # What a monthly cost really is, so the monthly figure is the one to compare.
    RECURRING_COST = /\b(?:subscriptions?|memberships?|gym|netflix|hulu|spotify|disney|streaming|dues)\b/i.freeze
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

    def self.reading(message)
      current = ParticipantMessageReader::Current
      current.reading if current.message == message.to_s
    end

    def self.item_label(message)
      item = reading(message)&.purchase_question.to_h["item"]
      return item if item.present?
      text = purchase_clause(message)
      tail = text[/\$\s*[\d,.]+(?:k\b)?\s+(?:for\s+)?(.+)/i, 1] || text[/\b(?:buy|purchase|afford|get|book|order)\s+(.+)/i, 1]
      tail = tail.to_s.sub(/\A(?:a|an|the)?\s*\d[\d,.]*\s+/, "")
      label = clean_item(tail)
        .sub(/\A(?:a|an|the|this)\s+/i, "").sub(/\Apair of\s+/i, "").strip
      return "" if label.blank? || label.match?(/\A(?:on|for|it|this|that|help|smaller goal|my streak|help|less|credit card|loan)\b/i)

      label.casecmp?("tv") ? "TV" : label.downcase
    end

    def self.clean_item(value)
      value.to_s.split(/[?.!;,]|\s+(?:or|on|using|for|with|from|at|next|this month|today|tomorrow|but|because|and|to|paid|paying)\b/i).first.to_s
    end

    def self.merchant_label(value)
      text = value.to_s.squish
      text
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
      return true if reading(message)&.purchase_question.to_h["item"].present? && !debt_question?(text)
      !debt_question?(text) && !text.match?(/\bspend less\b/i) &&
        MiaCoachAnswerer::PURCHASE_INTENT_PATTERNS.any? { |pattern| text.match?(pattern) } && item_label(text).present?
    end

    def self.read_only_purchase_question?(message)
      text = read_only_question_text(message)
      purchase_question?(message) && !MiaCoachAnswerer.explicit_write_request?(text)
    end

    # A funding description is not an instruction to reserve new money.
    def self.read_only_question_text(message)
      message.to_s.gsub(/\b(?:money|funds|cash)\s+(?:already\s+)?set aside\b/i, "reserved money")
    end

    # The reader catches every casual way of saying the money is not there;
    # the pattern is the floor when no reading is available.
    def self.unfunded?(text)
      MessageReplyIntent.matches?(text, "purchase_caution") || text.to_s.match?(/\b(?:don['’]?t|do not|dont really|don['’]?t really) (?:have|got) (?:the )?(?:money|cash|it)\b|\b(?:can['’]?t|cannot|won['’]?t|will not)\s+(?:pay|cover|afford)\b/i)
    end

    # An achievement without an amount is context, not evidence that a later
    # proposed purchase already happened. Completed amounts before it stay separate.
    def self.proposed_purchase_only?(message)
      text = message.to_s
      question = text.match(PURCHASE_QUESTION)
      return false unless question
      if defined?(ParticipantMessageReader)
        current = ParticipantMessageReader::Current
        return false if current.message.to_s.squish == text.squish && current.reading&.available && current.reading.facts.any? { |fact| fact["kind"] == "purchase" }
      end

      following = text[question.begin(0)..].split(/[?!;]/, 2).last.to_s if text[question.begin(0)..].match?(/[?!;]/)
      return false if PurchaseReportText.stated_amount?(following)
      return false if text[question.end(0)..].match?(/\b(?:,|\b(?:and|also|but|then|plus|after))\s*(?:(?:i|we)\s+)?(?:spent|paid|bought|saved)\b/i)

      !PurchaseReportText.stated_amount?(text[0...question.begin(0)])
    end

    def self.purchase_clause(message)
      text = message.to_s
      return text unless income_with_purchase?(text) || proposed_purchase_only?(text)

      question = text.match(PURCHASE_QUESTION)
      prefix = text[0...question.begin(0)]
      timing = /\A\s*(?:(?:next|this|last) (?:month|week|year)|today|tomorrow|in \d+ (?:days?|weeks?|months?|years?)|(?:(?:in|on|during|for)\s+)?(?:#{MonthTerms.pattern})(?:\s+20\d{2})?|\d{4}-\d{2}-\d{2})\s*[,;:]?\s*\z/i
      prefix.match?(timing) ? text : text[question.begin(0)..]
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
