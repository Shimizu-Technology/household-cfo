module HouseholdFinance
  # A small server floor for explicit non-writes. The reader supplies meaning;
  # these checks keep a misread question/negation from becoming a review card.
  module ParticipantMoneyIntent
    NO_CARD = /\b(?:dont|don['’]t|do not)\s+(?:make|create|prepare)\b[^.!?]{0,24}\b(?:card|review)\b/i
    NEGATED_PURCHASE = /\b(?:didn['’]?t|did not|never)\s+(?:actually\s+)?(?:spend|pay|buy|purchase)\b/i
    NEGATED_CHANGE = /\b(?:not|dont|don['’]t|do not)\s+(?:going\s+to\s+)?(?:changing|change|setting|set|making|make|updating|update)\b/i
    DEBT_REPAYMENT = /\b(?:paid|put)\s+\$?[\d,.]+\s+(?:extra\s+)?(?:on|toward|towards|to)\s+(?:(?:my|our|the)\s+)?(?:\w+\s+)?(?:visa|mastercard|amex|discover|credit card|card|loan|mortgage)\b(?!\s+(?:at|for|from)\b)/i
    ADVICE = /\A\s*(?:should\s+(?:i|we)\b|(?:is|would)\b.*\b(?:good|comfortable|reasonable|enough)\b)/i

    # A later plan to put it on a card is not spending yet. A completed move in
    # the same message keeps the reader's fact.
    def self.future_charge?(message)
      text = message.to_s
      text.match?(/\b(?:gonna|going to|about to|planning to|fixing to)\s+(?:charge|swipe|put)\b/i) && !text.match?(/\b(?:spent|bought|purchased|already charged)\b/i)
    end

    def self.debt_repayment?(message) = message.to_s.match?(DEBT_REPAYMENT)

    def self.blocked?(message, kind:)
      text = message.to_s
      return true if text.match?(NO_CARD)
      return text.match?(NEGATED_PURCHASE) if kind == :purchase
      text.match?(NEGATED_CHANGE) || text.match?(ADVICE)
    end
  end
end
