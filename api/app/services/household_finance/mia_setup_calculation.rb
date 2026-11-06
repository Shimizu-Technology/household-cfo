module HouseholdFinance
  # Only exact participant quotes become operands. Pending parts come back from
  # the household's persisted review, never from assistant prose or model sums.
  class MiaSetupCalculation
    attr_reader :clarification

    def initialize(message:, reading:, field: nil, prior: nil)
      @message, @reading, @field = message, reading, field
      @prior = prior.to_h.deep_symbolize_keys
    end

    def call
      details = (@reading.setup_details.presence || (@reading.question ? {} : bill_details)).deep_symbolize_keys
      return if @reading.care? || @reading.unclear_amount
      field = details[:field].presence || @reading.answer_field
      return unless field.in?(%w[primary_income fixed_expenses flexible_spend debt_payment])
      return ask if unsafe_expression?(field)
      components = details[:components]
      unless components.is_a?(Array) && components.any?
        return ask if @prior.present? && !explicit_total_replacement?(field)
        return
      end
      return ask unless components.length.between?(1, 12)
      if @reading.question
        facts = @reading.facts.select { |fact| fact["kind"] == (field == "primary_income" ? "income" : "bill") }.map { |fact| fact["amount"] }
        components.each do |component|
          index = facts.index(component[:amount])
          return ask unless index
          facts.delete_at(index)
        end
      end
      occupied = []
      operands = components.map do |component|
        source, amount = component.values_at(:source, :amount)
        return ask unless source.is_a?(String) && source.present? && amount.is_a?(String)
        start = @message.index(source)
        return ask unless start
        range = start...(start + source.length)
        return ask if occupied.any? { |old| old.overlap?(range) }
        occupied << range
        quote = source.match(/(?<![\w.,\/\-])#{Regexp.escape(amount)}(?![\w]|[.,]\d)/)
        return ask unless quote
        lead = source[0...quote.begin(0)].rstrip.sub(/\$\s*\z/, "").rstrip
        return ask if lead.end_with?("-", "−") || amount.match?(ParticipantMessageReader::MISPLACED_COMMA)
        cents = ParticipantMessageReader.amount_cents(amount)
        return ask unless cents.between?(0, Money::MAX_AMOUNT_CENTS)
        label = component_label(source, amount, field)
        return ask if label.blank? || label.match?(/\d/)
        { source: source, amount: amount, label: label }
      end
      return ask unless all_numbers_accounted_for?(components, details, field)
      if field == "primary_income"
        return ask unless details[:cadence] == "monthly_count" && operands.one? && @prior.blank?
        count = details[:count].to_s
        count_value = count.match?(/\A[1-5]\z/) ? count.to_i : { "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5 }[count.downcase]
        return ask unless count_value && @message.match?(/\b#{Regexp.escape(count)}\s+(?:pay\s?checks?|checks?)\b/i)
        total = cents_for(operands.sole) * count_value
        working = "#{count} × #{money(cents_for(operands.sole))} = #{money(total)}"
      else
        return ask unless details[:cadence] == "monthly"
        if @prior.present? && !explicit_total_replacement?(field)
          return ask unless @prior[:field] == field && @prior[:components].is_a?(Array) && @prior[:components].any?
          combined = @prior[:components].deep_dup
          operands.each do |operand|
            matches = combined.each_index.select { |index| same_label?(combined[index][:label], operand[:label]) }
            return ask if matches.many? || (matches.one? && !@reading.correction)
            return ask if matches.empty? && @reading.correction
            matches.one? ? combined[matches.sole] = operand : combined << operand
          end
          operands = combined
        end
        return ask unless operands.length.between?(1, 12)
        total = operands.sum { |operand| cents_for(operand) }
        labels = operands.map { |operand| "#{operand[:label]} #{money(cents_for(operand))}" }
        working = labels.one? ? labels.sole : "#{labels.join(' + ')} = #{money(total)}"
        working = working.sub(/\A./) { |letter| letter.upcase }
      end
      return ask if total > Money::MAX_AMOUNT_CENTS
      label = SetupStatus::FIELD_LABELS.fetch(field.to_sym).downcase
      { field: field, value: Money.dollars(total).to_s, components: operands, cadence: details[:cadence], count: details[:count].to_s,
        prior_draft_id: @prior[:draft_id],
        description: "#{working}. Is that your #{label} total? This is only the list you gave me. Add anything missing or correct a named part in chat before applying this card. Nothing saves until you apply it." }
    rescue ArgumentError, TypeError, NoMethodError
      ask
    end

    private

    def ask
      @clarification = "I can't safely total that list yet. Give each current monthly bill with its name and amount, or state the whole monthly total. For a correction, name the part to replace. Nothing changed."
      nil
    end

    def explicit_total_replacement?(field)
      return @message.match?(/\b(?:monthly|per month|a month)\b/i) if field == "primary_income"
      @message.match?(/\b(?:whole|overall|combined|fixed essentials|fixed expenses)\b[^.!?]*\btotal\b|\btotal\b[^.!?]*\b(?:fixed essentials|fixed expenses)\b/i)
    end

    def unsafe_expression?(field)
      return true if @message.match?(/\d[\d,.]*\s*(?:[-–]|\bto\b|\bthrough\b)\s*\$?\d|\b(?:half|quarter|percent|percentage)\b|%|\d\s*\/\s*\d|\b(?:since|due)\s+(?:(?:on|by)\s+)?(?:[a-z]+\s+)?\d|\bnot\b[^.!?;]*\d|\b(?:was|were|used to|last month)\b/i)
      return true if @message.match?(/\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+\d{1,2}\b/i)
      return true if @message.match?(/\b(?:weekly|bi-?weekly|a week|per week|each week|every (?:other |two |2 )?weeks?)\b/i)
      field != "primary_income" && @message.match?(/\btotal\b/i) && @message.scan(/\d[\d,.]*/).length > 1
    end

    def all_numbers_accounted_for?(components, details, field)
      remainder = @message.dup
      components.each do |component|
        source = component[:source]
        start = remainder.index(source)
        return false unless start
        local = source.index(component[:amount])
        return false unless local
        first = start + local
        remainder[first, component[:amount].length] = " " * component[:amount].length
      end
      if field == "primary_income"
        remainder = remainder.sub(/\b#{Regexp.escape(details[:count].to_s)}(?=\s+(?:pay\s?checks?|checks?)\b)/i, "")
      end
      !remainder.match?(/\d/)
    end

    def component_label(source, amount, field)
      return "paychecks" if field == "primary_income"
      source.sub(amount, "").sub(/\A\s*(?:(?:oh|and|wait|actually|also|the|my|our)\b[,\s]*)+/i, "")
        .sub(/\s+so far\s*\z/i, "").gsub(/\b(?:is|are|of|like|about|minimum|payment|min|monthly)\b/i, "")
        .delete("$=,:").squish
    end

    def same_label?(left, right)
      left.to_s.downcase.squish == right.to_s.downcase.squish
    end

    def cents_for(operand)
      ParticipantMessageReader.amount_cents(operand.fetch(:amount))
    end

    def bill_details
      return {} unless @field == "fixed_expenses"
      bills = @reading.facts.select { |fact| fact["kind"] == "bill" }
      return {} unless bills.any?
      components = bills.map do |bill|
        item, amount = bill.values_at("item", "amount")
        return {} if item.blank? || amount.blank?
        item_start, amount_start = @message.index(item), @message.index(amount)
        return {} unless item_start && amount_start
        first = [ item_start, amount_start ].min
        last = [ item_start + item.length, amount_start + amount.length ].max
        { source: @message[first...last], amount: amount }
      end
      { field: @field, cadence: "monthly", components: components }
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
