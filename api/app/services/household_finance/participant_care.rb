module HouseholdFinance
  # One model-independent care boundary for setup, household chat and the
  # challenge. Event + affected person + tense/negation determine the route.
  module ParticipantCare
    PERSON = /\b(?:i|we|my|our|me|us)\b/i.freeze
    GRIEF = /\b(?:died|dead|death|passed away|bereave\w*|griev\w*|mourning)\b/i.freeze
    PERSON_SUBJECT = /\b(?:(?:my|our|the)\s+(?:husband|wife|partner|spouse|mom|mum|mother|dad|father|parents?|child|children|kids?|son|daughter|brother|sister|grand\w*|aunt\w*|uncle|cousin|friend|family|baby|pet|dog|cat)|someone\s+(?:close|dear)\s+to\s+(?:me|us))\b/i.freeze
    WORK = /\b(?:job|work|employment|employer|laid off|fired|let (?:me|us) go)\b/i.freeze
    LOSS = /\b(?:lost|laid off|fired|let (?:me|us) go|unemployed|out of work)\b/i.freeze
    EVICTION = /\b(?:evict\w*|eviction|homeless)\b/i.freeze
    NON_EVENT = /\b(?:what if|suppose|hypothetical\w*|used to|last year|years? ago|back then)\b/i.freeze

    module_function

    def kind(message)
      text = message.to_s.tr("’", "'")
      # Conjunctions do not erase the subject, but sentence-level hypothetical
      # and negated events do not describe a present household hardship.
      text.split(/(?<=[.!?;])\s+/).each do |clause|
        next unless clause.match?(PERSON)
        next if clause.match?(NON_EVENT)
        return :grief if actual_event?(clause, GRIEF) &&
          (clause.match?(PERSON_SUBJECT) || clause.match?(/\b(?:i|we|i'm|we're)\b.{0,25}\b(?:griev\w*|mourning|bereave\w*)\b/i) || clause.match?(/\bdeath\b.{0,25}\b(?:my|our)\s+family\b/i))
        return :job_loss if clause.match?(WORK) && actual_event?(clause, LOSS)
        return :housing if actual_event?(clause, EVICTION)
      end
      return :food if MoneyMovementText.food_insecurity?(text)
      :essentials if MiaCoachAnswerer.essential_hardship?(text)
    end

    def actual_event?(clause, event)
      clause.to_enum(:scan, event).any? do
        prefix = Regexp.last_match.pre_match.split(/[,;]|\b(?:but|and)\b/i).last.to_s
        !prefix.match?(/\b(?:not|never|isn't|aren't|wasn't|weren't|haven't|hasn't|won't)\s+(?:[\p{L}']+\s+){0,3}\z/i)
      end
    end

    def required?(message)
      kind(message).present?
    end

    def answer(message)
      case kind(message)
      when :grief
        "I'm sorry for your loss. You don't have to work through money or setup right now. If it helps, reach out to your coach or someone you trust. We can pick this up when you're ready. What would feel most helpful today?"
      when :job_loss
        "Losing work is a lot to take in. Food, housing, utilities and medicine come first; savings and setup can wait. Your coach or someone you trust can help you think through the next step. We can pick this up when you're ready. What feels most urgent today?"
      when :housing
        "Facing the loss of your home is frightening. Housing and your other essentials come first; savings and setup can wait. Reach out to your coach or someone you trust, and ask your landlord about the notice and your options. We can pick this up when you're ready. What needs attention today?"
      end
    end
  end
end
