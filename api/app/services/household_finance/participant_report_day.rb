module HouseholdFinance
  # Calendar interpretation only. The reader quotes language; this resolves it
  # against the participant's local calendar, never the provider's clock.
  class ParticipantReportDay
    Result = Data.define(:state, :date, :phrase)
    AGO = /\b(?<count>\d+|#{PurchaseReportText::WORD_NUMBER})\s+days?\s+ago\b/i
    UNRESOLVED = /\b(?:(?:last|this) (?:week|weekend|month)|the other day|recently|a while ago)\b/i

    def self.call(day:, message:, today:)
      phrases = day.present? ? [ day ] : []
      if day.blank?
        message.scan(Regexp.union(PurchaseReportParser::DATE_PATTERN, AGO, UNRESOLVED)) { phrases << Regexp.last_match[0] }
      end
      return Result.new(:missing, nil, "") if phrases.empty?
      return Result.new(:unresolved, nil, phrases.join(" / ")) unless phrases.uniq.one?
      phrase = phrases.first
      if (match = phrase.match(/\A#{AGO.source}\z/i))
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
  end
end
