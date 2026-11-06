module HouseholdFinance
  module ParticipantCare
    module_function

    def kind(message)
      current = ParticipantMessageReader::Current
      return current.reading.care.to_sym if current.message == message.to_s && current.reading&.care?
      # Exact subject/action forms only during an outage or outside chat. Idioms
      # such as dead set/dead tired and fired up never satisfy these forms.
      text = message.to_s.tr("’", "'").strip
      return :grief if text.match?(/\A(?:my|our) (?:mom|dad|mother|father|husband|wife|sister|brother|grandfather|grandmother|nana) (?:just )?(?:died|passed away|passed)(?: (?:today|yesterday|this week|this weekend))?[.!]?\z/i)
      return :job_loss if text.match?(/\A(?:i lost my job|my employer (?:fired me|let me go))(?: (?:today|yesterday|last week))?[.!]?\z/i)
      return :housing if text.match?(/\Awe are about to be evicted[.!]?\z/i)
      return :food if MoneyMovementText.food_insecurity?(text)
      :essentials if MiaCoachAnswerer.essential_hardship?(text)
    end

    def required?(message) = kind(message).present?

    def answer(message)
      case kind(message)
      when :grief
        "I'm sorry for your loss. You don't have to work through money or setup right now. If it helps, reach out to your coach or someone you trust. We can pick this up when you're ready. What would feel most helpful today?"
      when :shame
        "This doesn't define your worth. We can take this one step at a time, when you're ready. What would feel most helpful today?"
      when :hardship, :job_loss, :housing
        "That sounds hard. Your safety, food, housing, utilities and medicine come first; savings and setup can wait. Reach out to your coach or someone you trust if that would help. We can pick this up when you're ready. What feels most urgent today?"
      end
    end
  end
end
