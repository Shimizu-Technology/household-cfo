module HouseholdFinance
  # A small server floor for explicit non-writes. The reader supplies meaning;
  # these checks keep a misread question/negation from becoming a review card.
  module ParticipantMoneyIntent
    NO_CARD = /\b(?:dont|don['’]t|do not)\s+(?:make|create|prepare)\b[^.!?]{0,24}\b(?:card|review)\b/i
    NEGATED_PURCHASE = /\b(?:didn['’]?t|did not|never)\s+(?:actually\s+)?(?:spend|pay|buy|purchase)\b/i
    NEGATED_CHANGE = /\b(?:not|dont|don['’]t|do not)\s+(?:changing|change|setting|set|making|make|updating|update)\b/i
    ADVICE = /\A\s*(?:should\s+(?:i|we)\b|(?:is|would)\b.*\b(?:good|comfortable|reasonable|enough)\b)/i

    def self.blocked?(message, kind:)
      text = message.to_s
      return true if text.match?(NO_CARD)
      return text.match?(NEGATED_PURCHASE) if kind == :purchase
      text.match?(NEGATED_CHANGE) || text.match?(ADVICE)
    end
  end
end
