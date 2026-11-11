module HouseholdFinance
  # Reads "the Target one yesterday was actually 64 not 46", "that Costco one
  # should be groceries" or "delete the 12 dollar Starbucks, it was a refund".
  # It only reads the words; the purchase is found in her own confirmed
  # purchases, and a card shows her the change before anything moves.
  class PurchaseChangeRequest
    Result = Data.define(:void, :new_cents, :old_cents, :category_text, :day)

    AMOUNT = /(?<![\w.])\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?![\w.]*\d)(?!\w)/.freeze
    VOID = /\b(?:delete|remove|void|scrap|get rid of|take (?:it |that |this )?(?:off|out)|undo)\b|\b(?:was|were|is|it was|that was)\s+(?:a\s+|an\s+)?(?:refund(?:ed)?|return(?:ed)?|mistake|accident|duplicate|double[- ]charge|cancel(?:l)?ed)\b|\b(?:didn['’]?t|did not|never)\s+(?:actually\s+)?(?:buy|spend|pay|happen|go through)\b|\b(?:shouldn['’]?t|should not)\s+(?:be\s+)?(?:counted|there|in (?:my|the|our) spending)\b|\bdon['’]?t count\b/.freeze
    NOT_AMOUNT = /\b(?:not|instead of|rather than|and not)\s+\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?!\w)/.freeze
    FROM_TO = /\bfrom\s+\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\s+to\s+\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?!\w)/.freeze
    CORRECTION_CUE = /\b(?:actually|really|should (?:have )?(?:be|been)|supposed to (?:be|have been)|(?:change|make|set|update|fix|correct|edit|adjust|switch)\b[^.?!]{0,60}?\bto)\s+(?:only\s+|about\s+|like\s+)?\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?!\w)/.freeze
    DOLLAR_BEFORE_WORD = /\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\s*(?:dollar|buck)s?\b|\$\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?=\s+[a-z])/.freeze
    CATEGORY_CUE = /(?:\bshould(?:n['’]?t)?\s+(?:be|go|have been)(?:\s+(?:in|under|on|to|filed under|counted (?:as|in)))?|\b(?:put|move|file|switch|change|recategori[sz]e|categori[sz]e|reclassify|count|log|mark)\b[^.?!]{0,50}?\b(?:to|as|in|under|into|on)|\b(?:is|was)\s+(?:really|actually)(?:\s+(?:in|under|for))?|\bbelongs?\s+(?:in|under|to))\s+(?:the\s+|my\s+|a\s+|an\s+)?(?<name>[a-z][a-z &\/'-]{1,40})/.freeze

    def self.parse(message, today: Date.current)
      new(message, today: today).call
    end

    def initialize(message, today:)
      @text = message.to_s.unicode_normalize(:nfkc).downcase.gsub(/[“”"]/, "").squish
      @today = today
    end

    def call
      return if text.blank? || text.length > 400

      void = text.match?(VOID)
      new_cents, old_cents = amounts unless void
      category = category_text unless void
      return unless void || new_cents || category_only?(category, old_cents: old_cents)

      old_cents ||= hinted_amount
      Result.new(void: void, new_cents: new_cents, old_cents: void || !new_cents ? (old_cents || hinted_amount) : old_cents, category_text: category, day: day)
    end

    private

    attr_reader :text, :today

    # A move to another category must point at a purchase she already made.
    # "I paid 64 at Target, should be groceries" is a new report instead.
    def category_only?(category, old_cents:)
      return false unless category
      return false if text.match?(/\b(?:i|we)\s+(?:just\s+)?(?:spent|paid|bought|got|ordered|grabbed)\b/) && !text.match?(/\b(?:actually|instead|not)\b/)

      text.match?(/\b(?:one|purchase|charge|transaction|payment|order|trip|receipt)\b/) || text.match?(/\A(?:that|the|this)\b/)
    end

    # [new, old]. A correction needs a cue, so "Target was 64 yesterday" stays a
    # new purchase report and not a change to an old one.
    def amounts
      if (match = text.match(FROM_TO))
        return [ cents(match[3], match[4]), cents(match[1], match[2]) ]
      end

      corrected = text.match(CORRECTION_CUE)
      old = text.match(NOT_AMOUNT)
      return [ cents(corrected[1], corrected[2]), old && cents(old[1], old[2]) ] if corrected

      [ nil, nil ]
    end

    # An amount used only to tell purchases apart ("the 12 dollar starbucks").
    def hinted_amount
      match = text.match(DOLLAR_BEFORE_WORD)
      return cents(match[1], match[2]) if match && match[1]
      return cents(match[3], match[4]) if match && match[3]

      single = text.scan(AMOUNT)
      single.one? ? cents(single.first[0], single.first[1]) : nil
    end

    def category_text
      match = text.match(CATEGORY_CUE)
      return unless match

      name = match[:name].strip.sub(/\s+(?:instead|please|though|now|too|again|not\b.*)\z/, "").sub(/[ ,.!?]+\z/, "")
      name.length >= 2 ? name : nil
    end

    def day
      result = ParticipantReportDay.call(day: "", message: text, today: today)
      result.state == :resolved && result.date <= today ? result.date : nil
    rescue StandardError
      nil
    end

    def cents(whole, fraction)
      Money.cents("#{whole.delete(',')}#{fraction.present? ? ".#{fraction}" : ''}")
    end
  end
end
