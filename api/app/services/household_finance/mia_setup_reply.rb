module HouseholdFinance
  # Positive evidence that a reply answers the question. A question's position
  # in a chat cannot turn an unrelated fact into a household goal or total.
  module MiaSetupReply
    module_function

    def goal?(message)
      text = message.to_s.squish
      explicit = text.match(/\b(?:(?:main|primary|money|financial|household)\s+)*goal\s+(?:is|:|to)\s+(.+)/i)
      text = explicit[1] if explicit
      text = text.sub(/\A(?:(?:i|we)\s+(?:want|hope|need|would like)\s+to|i['’]d like to)\s+/i, "")
      return false if text.match?(/\b(?:spent|bought|paid|saved|lost|cannot|can['’]?t|couldn['’]?t|didn['’]?t)\b/i)

      return true if explicit

      text.match?(/\A(?:to\s+)?(?:save\b|build\b|pay\s+off\b|pay\s+(?:my|our|the)\s+\w+\s+on time\b|reduce\b|grow\b|start\b|buy\b|own\b|retire\b|become\b|get\s+(?:out of|rid of)\b|help\s+(?:my|our)\b|stop\s+\w+|no\s+debt\b|debt[- ]free\b|financial\s+(?:freedom|security|stability)\b|(?:an?\s+)?emergency\s+(?:fund|cushion)\b)/i)
    end

    def bill_statement?(message)
      text = message.to_s
      !text.match?(/\?|\b(?:if|would|might|will|next|plan|want)\b/i) &&
        text.match?(/\b(?:rent|mortgage|utilities|(?:power|water|electric(?:ity)?|internet|phone)\s+bill)\b/i) &&
        text.match?(/\b(?:is|are|costs?|pay|owe|runs?|comes\s+to)\b/i) &&
        PurchaseReportText.stated_amount?(text)
    end

    def monthly_amount(message, field:)
      prefix = case field.to_s
      when "primary_income" then /\A(?:i|we)\s+(?:take|bring)\s+home\s+/i
      when "fixed_expenses" then /\A(?:i|we)\s+(?:pay|spend)\s+/i
      when "flexible_spend" then /\A(?:i|we)\s+spend\s+/i
      end
      return unless prefix
      text = message.to_s.squish
      return unless text.match?(prefix)
      rest = text.sub(prefix, "")
      tail = field.to_s == "flexible_spend" ? '(?:\\s+on\\s+(?:groceries|gas|food|everyday spending)(?:[\\p{L} ,&-]*))?' : ""
      match = rest.match(/\A(?:about|around|roughly)?\s*\$?\s*(#{Money::CHAT_NUMBER_SOURCE}#{Money::CHAT_THOUSANDS_SOURCE}?)\s+(?:a|per|each)\s+month#{tail}[.!]?\z/i)
      return unless match
      cents = Money.chat_cents(match[1])
      Money.dollars(cents).to_s if cents.between?(0, Money::MAX_AMOUNT_CENTS)
    rescue ArgumentError
      nil
    end
  end
end
