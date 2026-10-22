module HouseholdFinance
  # Normalize only explicit money units and review instructions. Bare number
  # words ("two kids", "twelve fifty") are never guessed to be money.
  module PurchaseReportText
    SMALL = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen].each_with_index.to_h.freeze
    TENS = { "twenty" => 20, "thirty" => 30, "forty" => 40, "fifty" => 50, "sixty" => 60, "seventy" => 70, "eighty" => 80, "ninety" => 90 }.freeze
    UNIT_SOURCE = "(?:#{SMALL.keys.join('|')})"
    TENS_SOURCE = "(?:#{TENS.keys.join('|')})(?:[ -](?:one|two|three|four|five|six|seven|eight|nine))?"
    UNDER_HUNDRED = "(?:#{TENS_SOURCE}|#{UNIT_SOURCE})"
    WORD_NUMBER = "(?:#{UNIT_SOURCE} hundred(?: (?:and )?#{UNDER_HUNDRED})?|#{UNDER_HUNDRED})"
    NUMBER = "(?:#{Money::CHAT_NUMBER_SOURCE}|#{WORD_NUMBER})"
    WORD_TOKEN = "(?:#{(SMALL.keys + TENS.keys + %w[hundred thousand million]).join('|')})"
    WRITTEN_NUMBER = "(?:\\d[\\d,.]*|#{WORD_TOKEN}(?:[ -](?:#{WORD_TOKEN}|and)){0,12})"
    UNCLEAR_AMOUNT = "__unclear_purchase_amount__".freeze
    UNITS = /(?<![\w$.,-])(?:\$\s*)?(?<dollars>#{WRITTEN_NUMBER})\s+(?:dollars?|bucks)\b(?:\s+and\s+(?<cents>#{WRITTEN_NUMBER})\s+cents?\b)?/i.freeze
    CENTS = /(?<![\w$.,-])(?<cents>#{WRITTEN_NUMBER})\s+cents?\b/i.freeze
    # Complete trailing sentences only: negation of buying remains untouched.
    REVIEW_SENTENCE = /(?:\A|(?<=[.!])\s+)(?:please\s+)?(?:prepare\s+(?:one|a)\s+(?:check-in|review)\s+card\s+for\s+me\s+to\s+review|(?:don['’]?t|do\s+not)\s+save\s+(?:these\s+purchases|this|anything)\s+until\s+I\s+approve)[.!]?\s*\z/i.freeze

    module_function

    def normalize(value, preserve_layout: false)
      text = value.to_s.unicode_normalize(:nfkc).gsub(/\r\n?/, "\n").strip
      return text if text.length > 2_000

      loop do
        previous = text
        text = text.sub(REVIEW_SENTENCE) { |literal| replacement(literal, "", preserve_layout) }.rstrip
        break if text == previous
      end
      text = text.sub(/\Afor\s+(?:today['’]s|my|our)\s+check-in[, :]*/i) { |literal| replacement(literal, "", preserve_layout) }
      text = text.gsub(/\s+and\s+(?:(?:I|we)\s+)?(?:bought|purchased)\s+nothing\s+else(?=[.!]|\s*\z)/i) { |literal| replacement(literal, "", preserve_layout) }
      text = text.gsub(UNITS) do |literal|
        match = Regexp.last_match
        next literal if merchant_prefix?(text, match.begin(0))

        dollars = number(match[:dollars])
        cents = match[:cents] ? number(match[:cents]) : 0
        if dollars && cents && cents.between?(0, 99) && cents.to_i == cents && (!match[:cents] || dollars.to_i == dollars)
          replacement(literal, "$#{format('%.2f', dollars + BigDecimal(cents.to_s) / 100)}", preserve_layout)
        else
          replacement(literal, UNCLEAR_AMOUNT, preserve_layout)
        end
      end
      text.gsub(CENTS) do |literal|
        match = Regexp.last_match
        # A merchant such as "99 Cents Only" follows at/from, not a price verb.
        next literal if merchant_prefix?(text, match.begin(0))

        cents = number(match[:cents])
        replacement(literal, cents && cents.between?(0, 99) && cents.to_i == cents ? "$#{format('%.2f', BigDecimal(cents.to_s) / 100)}" : UNCLEAR_AMOUNT, preserve_layout)
      end
    end

    def merchant_prefix?(text, offset)
      text[0...offset].match?(/(?:\bat|\bfrom|@)\s+(?:the\s+)?\z/i)
    end

    def replacement(literal, normalized, preserve_layout)
      preserve_layout ? normalized.ljust(literal.length) : normalized
    end

    def number(value)
      return unless value.match?(/\A#{NUMBER}\z/i)
      return BigDecimal(value.delete(",")) if value.match?(/\A[\d,]+(?:\.\d{1,2})?\z/)

      words = value.downcase.tr("-", " ").split.reject { |word| word == "and" }
      total = 0
      words.each do |word|
        if word == "hundred"
          total *= 100
        else
          total += SMALL.fetch(word) { TENS.fetch(word) }
        end
      end
      total
    end
  end
end
