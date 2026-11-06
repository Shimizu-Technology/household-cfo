module HouseholdFinance
  # Positive evidence that a reply answers the question. A question's position
  # in a chat cannot turn an unrelated fact into a household goal or total.
  module MiaSetupReply
    module_function

    def confirmation_updates(messages)
      index = messages.rindex { |turn| turn[:role] == "assistant" }
      return unless index
      question = messages[index][:content].to_s
      match = question.match(/\bis your household name\s+["“'‘](.+?)["”'’],?\s+and is\s+\$?\s*(#{Money::CHAT_NUMBER_SOURCE}#{Money::CHAT_THOUSANDS_SOURCE}?)\s+your monthly (?:take[ -]home )?income\?["”]?\s*\z/i)
      return unless match

      name, amount = match.captures
      cents = Money.chat_cents(amount)
      return {} unless cents.between?(0, Money::MAX_AMOUNT_CENTS) && name.length <= 120
      sources = messages.take(index).filter_map { |turn| turn[:content].to_s.squish if turn[:role] == "user" }
        .reject { |text| text.match?(/\?|\b(?:not|isn['’]?t|don['’]?t|if|would|could|might)\b/i) }
      name_known = sources.any? do |text|
        source = text[/\b(?:household (?:is called|name is)|call it)\s+([^.!?]+)/i, 1] || text
        source = source.sub(/[.!]\z/, "").squish
        source.match?(/\A[\p{L}\p{M}\d '&-]+\z/) && (source.casecmp?(name) || source.downcase.start_with?("#{name.downcase} of "))
      end
      income_facts = sources.filter_map do |text|
        raw = text.match(MiaIntentResolver::GUIDED_MONEY_REPLY_PATTERN)&.[](1) || text.match(MiaSetupIntake::PATTERNS.fetch(:primary_income))&.[](1)
        Money.chat_cents(raw) if raw
      end
      return {} unless name_known && income_facts.last == cents

      { household_name: name, primary_income: Money.chat_amount_text(amount) }
    rescue ArgumentError
      {}
    end

    def goal?(message)
      current = ParticipantMessageReader::Current
      current.message == message.to_s && current.reading&.answer_field == "primary_goal"
    end

    def question?(message)
      message.match?(/\?|\A(?:what|why|how|when|where|which|can|could|should|would|do|does|did|is|are)\b/i)
    end

    def purchase_statement?(message)
      return false unless PurchaseReportText.stated_amount?(message)
      message.match?(/\b(?:spent|bought|paid|purchased|buy)\b/i) ||
        message.match?(/\bat\s+[\p{L}]/i)
    end

    def income_statement?(message)
      PurchaseReportText.stated_amount?(message) &&
        message.match?(/\b(?:income|salary|paycheck|wages?)\b\s+(?:is|are|was|comes? to)\b/i)
    end

    def bill_statement?(message)
      text = message.to_s
      !text.match?(/\?|\b(?:if|would|might|will|next|plan|want)\b/i) &&
        text.match?(/\b(?:rent|mortgage|utilities|(?:power|water|electric(?:ity)?|internet|phone)\s+bill)\b/i) &&
        text.match?(/\b(?:is|are|costs?|pay|owe|runs?|comes\s+to)\b/i) &&
        PurchaseReportText.stated_amount?(text)
    end

    def monthly_amount(message, field:)
      text = message.to_s.squish
      if field.to_s == "primary_income" && text.match?(/\A(?:(?:i|we)\s+(?:have|earn|make)\s+)?no\s+income[.!]?\z/i)
        return "0"
      end
      normalized = PurchaseReportText.normalize(text)
      prefix = case field.to_s
      when "primary_income" then /\A(?:i|we)\s+(?:(?:take|bring)\s+home|make|earn|receive)\s+/i
      when "fixed_expenses" then /\A(?:i|we)\s+(?:pay|spend)\s+/i
      when "flexible_spend" then /\A(?:i|we)\s+spend\s+/i
      end
      return unless prefix && normalized.match?(prefix)
      rest = normalized.sub(prefix, "")
      match = rest.match(/\A(?:about|around|roughly|approximately)?\s*\$?\s*(#{Money::CHAT_NUMBER_SOURCE}#{Money::CHAT_THOUSANDS_SOURCE}?)\s*(.*?)[.!]?\z/i)
      return unless match
      tail = match[2].squish
      cadence = /(?:(?:a|per|each|every)\s+month|monthly)/i
      valid_tail = case field.to_s
      when "primary_income" then tail.match?(/\A#{cadence}\z/i)
      when "fixed_expenses" then tail.match?(/\A(?:#{cadence}(?:\s+(?:in|on|for)\s+(?:bills|fixed essentials))?|(?:in|on|for)\s+(?:bills|fixed essentials)(?:\s+#{cadence})?)\z/i)
      when "flexible_spend" then tail.match?(/\A#{cadence}(?:\s+on\s+(?:groceries|gas|food|everyday spending)(?:[\p{L} ,&-]*))?\z/i)
      end
      return unless valid_tail
      cents = Money.chat_cents(match[1])
      Money.dollars(cents).to_s.sub(/\.0+\z/, "") if cents.between?(0, Money::MAX_AMOUNT_CENTS)
    rescue ArgumentError
      nil
    end
  end
end
