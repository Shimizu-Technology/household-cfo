module HouseholdFinance
  # The reader identifies operands. Ruby validates their exact, disjoint source
  # spans and does all arithmetic. The output is only input to a pending review.
  class MiaSetupCalculation
    def initialize(message:, reading:, field: nil)
      @message, @reading, @field = message, reading, field
    end

    def call
      details = @reading.setup_details.presence || (@reading.question ? {} : bill_details)
      return if @reading.care? || @reading.unclear_amount
      field = details["field"]
      return unless field.in?(%w[primary_income fixed_expenses flexible_spend debt_payment])
      components = details["components"]
      return unless components.is_a?(Array) && components.length.between?(1, 12)
      if @reading.question
        facts = @reading.facts.select { |fact| fact["kind"] == (field == "primary_income" ? "income" : "bill") }.map { |fact| fact["amount"] }
        components.each do |component|
          index = facts.index(component["amount"])
          return unless index
          facts.delete_at(index)
        end
      end
      occupied = []
      amounts = components.map do |component|
        return unless component.is_a?(Hash)
        source, amount = component.values_at("source", "amount")
        return unless source.is_a?(String) && source.present? && amount.is_a?(String)
        start = @message.index(source)
        return unless start
        range = start...(start + source.length)
        return if occupied.any? { |old| old.overlap?(range) }
        occupied << range
        quoted = source.match(/(?<![\w.,\/\-])#{Regexp.escape(amount)}(?![\w]|[.,]\d)/)
        return unless quoted
        lead = source[0...quoted.begin(0)].rstrip.sub(/\$\s*\z/, "").rstrip
        return if lead.end_with?("-", "−")
        return if amount.match?(ParticipantMessageReader::MISPLACED_COMMA)
        ParticipantMessageReader.amount_cents(amount)
      end
      return unless amounts.all? { |amount| amount.between?(0, Money::MAX_AMOUNT_CENTS) }
      if field == "primary_income"
        return unless details["cadence"] == "monthly_count" && amounts.one?
        count = details["count"]
        count_value = count.to_s.match?(/\A[1-5]\z/) ? count.to_i : { "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5 }[count.to_s.downcase]
        return unless count_value && @message.match?(/\b#{Regexp.escape(count)}\b/)
        return if @message.match?(/\b(?:bi-?weekly|weekly|every (?:other|two|2) weeks?)\b/i) && !@message.match?(/\b(?:this month|per month|monthly|a month)\b/i)
        total = amounts.sole * count_value
        working = "#{count} × #{money(amounts.sole)} = #{money(total)}"
      else
        return unless details["cadence"] == "monthly"
        total = amounts.sum
        working = "#{amounts.map { |amount| money(amount) }.join(' + ')} = #{money(total)}"
      end
      return if total > Money::MAX_AMOUNT_CENTS
      label = SetupStatus::FIELD_LABELS.fetch(field.to_sym).downcase
      { field: field, value: Money.dollars(total).to_s,
        description: "#{working}. Is that your #{label} total? This is only the list you gave me. Add anything missing or correct the total in chat before applying this card. Nothing saves until you apply it." }
    rescue ArgumentError, TypeError
      nil
    end

    private

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
        { "source" => @message[first...last], "amount" => amount }
      end
      { "field" => @field, "cadence" => "monthly", "components" => components }
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
