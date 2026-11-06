module HouseholdFinance
  # Calendar interpretation only. The reader quotes language; this resolves it
  # against the participant's local calendar, never the provider's clock.
  class ParticipantReportDay
    Result = Data.define(:state, :date, :phrase)
    AGO = /\b(?<count>\d+|#{PurchaseReportText::WORD_NUMBER})\s+days?\s+ago\b/i
    TOMORROW = /\b(?:tomorrow|next week|next month)\b/i
    HOLIDAY = /\bon\s+halloween\b/i
    UNRESOLVED = /\b(?:(?:last|this) (?:week|weekend|month)|the other day|recently|a while ago)\b/i

    def self.call(day:, message:, today:)
      day = "" if day.present? && message.present? && !message.include?(day)
      if day.to_s.casecmp?("halloween")
        day = message.match?(HOLIDAY) ? "on halloween" : ""
      end
      phrases = day.present? ? [ day ] : []
      if day.blank?
        message.scan(Regexp.union(PurchaseReportParser::DAY_PATTERN, AGO, UNRESOLVED, HOLIDAY, TOMORROW)) do
          match = Regexp.last_match
          phrases << match[0] unless ordinary_weekday_word?(match)
        end
      end
      return Result.new(:missing, nil, "") if phrases.empty?
      return Result.new(:unresolved, nil, phrases.join(" / ")) unless phrases.uniq.one?
      phrase = normalize(phrases.first)
      if phrase.match?(/\Atomorrow\z/i)
        date = today + 1
      elsif phrase.match?(/\A#{HOLIDAY.source}\z/i)
        date = Date.new(today.year, 10, 31)
        date = Date.new(today.year - 1, 10, 31) if date > today
      elsif (match = phrase.match(/\A#{AGO.source}\z/i))
        count = PurchaseReportText.number(match[:count])
        date = today - count.to_i if count && count.between?(0, 3660) && count.to_i == count
      else
        calendar = PurchaseReportParser::Calendar.new(today - 3660, today + 3660, today)
        parser = PurchaseReportParser.new(calendar, message: phrase)
        tokens = parser.send(:date_tokens, phrase)
        date = tokens.sole[:date] if tokens.one? && tokens.sole[:range].begin.zero? && tokens.sole[:range].end == phrase.length
      end
      Result.new(date ? :resolved : :unresolved, date, phrase)
    end

    # A period of the day refines the stated day; it never changes its date.
    # Unique weekday prefixes share the same expansion in both intake paths.
    def self.normalize(value)
      text = value.to_s.downcase.squish.sub(/[.!]\z/, "")
      without_period = text.sub(/\s+(?:in the\s+)?(?:morning|afternoon|evening|night)\z/, "")
      text = without_period unless without_period.in?(%w[last this])
      text.gsub(/\b[a-z]+\b/) do |word|
        if word.length >= 3 && (day = PurchaseReportParser::WEEKDAYS.find { |name| name.start_with?(word) })
          day
        elsif word.length >= 4 && "yesterday".start_with?(word)
          "yesterday"
        else
          word
        end
      end
    end

    # The reader quotes a stated day. In this fallback scan a bare "sunday school"
    # or "monday was rough" is an ordinary word, not the day of the report.
    def self.ordinary_weekday_word?(match)
      match[:weekday].to_s.downcase.in?(PurchaseReportParser::WEEKDAYS) && match[0].casecmp?(match[:weekday]) && !match.pre_match.match?(/\b(?:this|past)\s+\z/i)
    end
    private_class_method :ordinary_weekday_word?
  end
end
