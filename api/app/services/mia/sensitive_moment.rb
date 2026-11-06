# frozen_string_literal: true

module Mia
  # Deterministic floor; the independent guard can only tighten this routing.
  module SensitiveMoment
    GRIEF = /\b(?:passed away|(?:my|our)\s+(?:[\w’'-]+\s+){0,2}(?:mom|mother|dad|father|son|daughter|husband|wife|spouse|partner|brother|sister|parents?|grand\w+|friend|baby|child|uncle|aunt|cousin)\b[^.!?]{0,25}\b(?:died|death)|bereave\w*|griev\w*|mourning|funeral|casket)\b/i.freeze
    STRAIN = /\b(?:(?:went|go|going) without (?:food|meals?)|lost my job|(?:laid|laying) off|make ends meet|(?:can['’]?t|cannot)\s+(?:make|pay|cover|afford|buy)\s+(?:(?:my|our|the|any)\s+)?(?:rent|food|groceries|minimum(?:s| payments?)?|bills?)|hate myself|feel like a loser|(?:i|we)(?:[\u0027’](?:m|re)|\s+(?:am|are|feel|felt))\s+(?:[\w’\u0027-]+\s+){0,4}(?:crying|worthless|failure|guilty|ashamed|shame))\b/i.freeze

    def self.grief?(text) = text.to_s.match?(GRIEF)

    def self.matches?(text)
      current = HouseholdFinance::ParticipantMessageReader::Current
      if current.message.to_s.squish == text.to_s.squish && current.reading&.available
        return current.reading.care? || HouseholdFinance::ParticipantCare.required?(text)
      end
      grief?(text) || text.to_s.match?(STRAIN) || CrisisBoundary.matches?(text) || CrisisBoundary.hopeless?(text) ||
        HouseholdFinance::MoneyMovementText.food_insecurity?(text) || HouseholdFinance::MiaCoachAnswerer.essential_hardship?(text)
    end

    def self.response(text)
      return CrisisBoundary.response if CrisisBoundary.matches?(text)
      return care if (care = HouseholdFinance::ParticipantCare.answer(text))
      if HouseholdFinance::MoneyMovementText.food_insecurity?(text) || text.to_s.match?(/\b(?:without meals|can['’]?t buy food|cannot buy food)\b/i)
        return "Going without food is hard, and you deserve to eat. Please talk with your coach or someone you trust about getting food today. Does everyone at home have enough to eat today?"
      end
      return "I'm sorry for your loss. You do not have to sort out this money decision right now. Could your coach or someone you trust sit with you while you consider what needs attention first?" if grief?(text)

      "This sounds hard, and it does not make you a failure. Protect food, housing, and required payments first, and consider talking with your coach or someone you trust. What feels most urgent right now?"
    end
  end
end
