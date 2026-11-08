module HouseholdFinance
  # Arithmetic is a closed grammar over the participant's message. The reader
  # supplies care/question context, never operands, labels, cadence or permission.
  class MiaSetupCalculation
    AMOUNT = /\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?/
    MONTHLY = /(?:a\s+month|monthly|\/mo)/i
    CLAUSE = /\A(?<label>[\p{L}]+(?:\s+[\p{L}]+)*?)\s*(?:(?:is|=|:)\s*)?(?:(?:like|about)\s+)?(?<amount>#{AMOUNT})\s*(?:#{MONTHLY})?\z/i
    NONLABEL = /\b(?:oops|wait|forgot|sorry|minus|negative|less|like|about|if|would|could|should|can|will|might|suppose|whether|no|never|dont|ow(?:e[sd]?|ing)|min|minimum|balances?|each|per|weeks?|weekly|biweekly|years?|yearly|annual|days?|paychecks?|between|up|to|or|maybe|totals?|last|was|were|back|in|ago|deposits?|percent|since|due|not|half|quarter|quarterly|every|other|two|three|four|five|six|seven|eight|nine|ten|one|hundred|thousand|bought|paid|spent|purchase|we|i|pay|make|at|of|actually|is|are)\b|%/i
    ASK = "What's the total for all of those each month? I'll put it on a review card, and nothing saves until you apply it.".freeze
    attr_reader :clarification

    def initialize(message:, reading:, field: nil, prior: nil)
      @message, @reading = message.to_s, reading
      @field = field.presence || reading&.answer_field
      @prior = prior.to_h.deep_symbolize_keys
    end

    def call
      return if @reading&.care? || @reading&.question
      return unless @field.in?(%w[primary_income fixed_expenses flexible_spend debt_payment])
      text = @message.strip.sub(/[.!]\z/, "")
      return if text.blank? || !text.match?(/\d/) && @prior.blank?
      text = text.sub(/\A(?:(?:so|ok(?:ay)?|well)[, ]+)+(?:let['’]?s start over[., ]+)?/i, "")
      if @prior.present? && (removed = removal_label(text))
        parts = @prior[:components].to_a.deep_dup
        matches = matching_parts(parts, removed)
        return ask_part(removed) unless matches.one?
        parts.delete_at(matches.sole)
        return ask if parts.empty?
        return result(parts)
      end
      if @prior.present? && (whole = text.match(/\A(?:the )?(?:(?:whole|overall|combined) (?:monthly )?total|fixed (?:essentials|expenses) total)\s*(?:(?:is|=|:)\s*)?(?<amount>#{AMOUNT})\s*(?:#{MONTHLY})?\z/i))
        return result([ { source: @message.strip, label: "whole total", amount: whole[:amount] } ])
      end
      return if @prior.blank? && (text.match?(MiaIntentResolver::GUIDED_MONEY_REPLY_PATTERN) || MiaSetupReply.monthly_amount(@message, field: @field))
      return if @prior.blank? && text.match?(/\A#{AMOUNT}\s+(?:including|with)\s+groceries\z/i)
      # A bare figure is handled by the existing one-answer path. It is not a
      # named pending-part replacement, and cannot discard the pending list.
      return @prior.present? ? ask : nil if text.match?(/\A#{AMOUNT}\z/)
      return if @prior.blank? && text.match?(/\A(?:oops|wait|actually)\s+#{AMOUNT}\z/i)
      scalar = text.match(/\A(?:actually|wait|oops)\s+(?:(?:my|our|the)\s+)?(?<label>fixed essentials|fixed expenses|monthly income|income|flexible spending)\s+is\s+(?<amount>#{AMOUNT})\s*(?:#{MONTHLY})?\z/i)
      if scalar
        target = scalar[:label].match?(/income/i) ? "primary_income" : scalar[:label].match?(/flexible/i) ? "flexible_spend" : "fixed_expenses"
        return ask if @prior.present? && @prior[:field] == target
        @field, @prior = target, {}
        return result([ { source: @message.strip, label: scalar[:label], amount: scalar[:amount] } ])
      end
      return if @field == "primary_income" && text.match?(/\A(?:we|i)\s+(?:bring\s+(?:home|in)|take\s+home|make|earn)\s+#{AMOUNT}\s*(?:#{MONTHLY})?\z/i)
      return if !text.match?(/,|\band\b/i) && text.match?(/\b(?:spent|bought|purchased|paid)\b/i) && !MiaSetupReply.bill_statement?(text)
      return if reported_purchases?(text)
      correction = text.match?(/\A(?:no wait|wait|actually|oops|sorry no make)\b/i)
      text = text.sub(/\A(?:forgot|oh and|also|no wait|wait|actually|oops|sorry no make)\s+(?:the\s+)?/i, "") if @prior.present?
      clauses = text.split(/,\s+|,(?=[^\d\s]|\z)|\s+and\s+/i, -1).map(&:strip)
      return ask unless clauses.length.between?(1, 8)
      parts = if @field == "primary_income" && clauses.all? { |clause| clause.match?(/\A#{AMOUNT}\z/) }
        clauses.map { |clause| { source: clause, amount: clause, label: "" } }
      else
        clauses.map do |clause|
          match = CLAUSE.match(clause)
          return ask unless match && !match[:label].match?(NONLABEL)
          { source: clause, amount: match[:amount], label: match[:label].strip }
        end
      end
      return ask if parts.many? && parts.any? { |part| part[:label].match?(/\b(?:bills|expenses|essentials|combined|overall|all|altogether)\b/i) }
      return ask unless parts.all? { |part| cents_for(part).between?(0, Money::MAX_AMOUNT_CENTS) }
      if @prior.present?
        return ask if parts.any? { |part| part[:label].blank? }
        return ask unless @prior[:field] == @field && @prior[:components].is_a?(Array)
        return ask if @prior[:components].any? { |part| part[:label] == "whole total" }
        combined = @prior[:components].deep_dup
        parts.each do |part|
          matches = matching_parts(combined, part[:label])
          return ask_part(part[:label]) if matches.many? || (matches.one? && !correction) || (matches.empty? && correction)
          matches.one? ? combined[matches.sole] = part : combined << part
        end
        parts = combined
      end
      result(parts)
    rescue ArgumentError, TypeError, NoMethodError
      ask
    end

    private

    def reported_purchases?(text)
      body = text.sub(/\A(?:(?:i|we)\s+)?spent\s+/i, "")
      return false if body == text
      body.split(/,\s+|\s+and\s+/i).all? { |part| part.match?(/\A#{AMOUNT}\s+at\s+[\p{L}][\p{L} '’&.\-]*\z/i) }
    end

    def removal_label(text)
      match = text.match(/\A(?:actually\s+)?no\s+(?:the\s+)?(?<label>[\p{L} '’ -]+?)(?:\s+bill)?\s*,\s*it['’]?s included in (?:the )?rent now\z/i) ||
        text.match(/\Ascratch\s+(?:the\s+)?(?<label>[\p{L} '’ -]+?)\s*,\s*we don['’]?t pay for that anymore\z/i)
      match&.[](:label)
    end

    def matching_parts(parts, label)
      words = label_words(label)
      return [] if words.empty?
      parts.each_index.select { |index| label_words(parts[index][:label]) == words }
    end

    def label_words(label)
      label.to_s.downcase.scan(/[\p{L}]+/) - %w[the my our bill]
    end

    def ask
      @clarification = ASK
      nil
    end

    def ask_part(label)
      @clarification = "Which part should I change for #{label}? The earlier list is still on its review card. Nothing changed."
      nil
    end

    def result(parts)
      return ask unless parts.length.between?(1, 8)
      total = parts.sum { |part| cents_for(part) }
      return ask if total > Money::MAX_AMOUNT_CENTS
      labels = parts.map { |part| [ part[:label].presence, money(cents_for(part)) ].compact.join(" ") }
      working = labels.one? ? labels.sole : "#{labels.join(' + ')} = #{money(total)}"
      working = working.sub(/\A./) { |letter| letter.upcase }
      label = SetupStatus::FIELD_LABELS.fetch(@field.to_sym).downcase
      { field: @field, value: Money.dollars(total).to_s, components: parts, cadence: "monthly", count: "",
        prior_draft_id: @prior[:draft_id],
        description: "#{working}. Is that your #{label} total? This is only the list you gave me. Add anything missing, correct or remove a named part in chat before applying this card. Nothing saves until you apply it." }
    end

    def cents_for(part) = ParticipantMessageReader.amount_cents(part.fetch(:amount))

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
