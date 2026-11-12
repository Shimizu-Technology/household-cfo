module SavingsChallenge
  # Wording offers a card. Only an explicit card action tells the coach.
  module ParticipantHelp
    REMINDERS = /\b(?:reminders?|notifications?|alerts?)\b/i
    EXIT = /\b(?:leav(?:e|ing)|quit(?:ting)?|paus(?:e|ing)|withdraw(?:ing)?|cancel(?:l?ing)?|get(?:ting)? out of|drop out|opt out|step(?:ping)? (?:back|away)|take (?:a )?break|tak(?:e|ing) me out|done with (?:this|the) challenge|stop(?:ping)? (?:the |my |this )?(?:challenge|program))\b/i
    VETO = /\b(?:don['’]?t|dont|do not|never)\s+(?:tell|notify|let)\b/i
    RETRACTION = /\b(?:don['’]?t|dont|do not|not ready to|never)\s+(?:want to\s+)?(quit|leave|pause|stop|withdraw)\b/i
    MEANING = "Stepping away would stop your daily check-ins, and what you've already saved stays in your record.".freeze
    EXPLANATION = "You can't leave or pause the challenge yourself in the app yet. #{MEANING} Nothing has changed. Use the card below if you'd like your coach to know.".freeze
    REMINDER_ANSWER = "You can change challenge reminders without leaving. Open Privacy & reminders and turn off the reminders you don't want. Nothing about your challenge has changed.".freeze

    def self.exit_text(message)
      message.to_s.gsub(/\b(?:pause|stop|cancel|turn off)\s+(?:the |this |my )?(?:challenge )?(?:reminders?|notifications?|alerts?)\b/i, "")
    end

    # The exit verb must target the challenge, not merely share a sentence
    # with it ("quit smoking when does my challenge end?"). A short standalone
    # exit is also clear in the selected challenge conversation.
    def self.challenge_exit?(match)
      return true if match[0].match?(/\b(?:challenge|program)\b/i)
      tail = match.post_match
      return true if tail.match?(/\A\s+(?:or\s+(?:leave|quit|pause|stop|withdraw)\s+)?(?:(?:from|of|in)\s+)?(?:(?:the|this|my|our)\s+)?(?:savings\s+)?(?:challenge|program)\b/i)
      match[0].match?(/\A(?:quit|leave|pause|cancel|withdraw|drop out|opt out|take me out)\z/i) && tail.match?(/\A[.!?,; ]*\z/)
    end

    def self.leave_mention?(text)
      text.split(/[.!?;,]|\b(?:and|but)\b/i).any? do |clause|
        clause.to_enum(:scan, EXIT).any? { challenge_exit?(Regexp.last_match) }
      end
    end

    def self.exit?(message) = leave_mention?(exit_text(message)) || message.to_s.match?(REMINDERS)

    def self.card_intents(message)
      text = exit_text(message)
      return [] unless leave_mention?(text)
      return [] if text.match?(VETO)
      intents = []
      text.split(/[.!?;,]|\b(?:and|but)\b/i).each do |part|
        next unless leave_mention?(part)
        if (refusal = part.match(RETRACTION))
          if refusal[1].casecmp?("stop")
            intents.clear
          else
            intents.delete(refusal[1].casecmp?("pause") ? "pause" : "leave")
          end
          next
        end
        next unless part.match?(EXIT)
        part.to_enum(:scan, EXIT).each do
          match = Regexp.last_match
          next unless challenge_exit?(match)
          word = match[0]
          if word.match?(/\b(?:stop|stopping|step(?:ping)? away)\b/i)
            intents.concat(%w[leave pause])
          else
            intents << (word.match?(/\b(?:pause|pausing|break|step(?:ping)? back)\b/i) ? "pause" : "leave")
          end
        end
      end
      intents.uniq
    end

    def self.reminder_answer(message)
      return REMINDER_ANSWER.sub("turn off the reminders you don't want", "turn on the reminders you want") if message.to_s.match?(/\b(?:turn on|enable|start|resume)\b/i)
      REMINDER_ANSWER
    end

    def self.exit_answer(message, **)
      return unless exit?(message)
      parts = []
      if leave_mention?(exit_text(message))
        parts << (card_intents(message).empty? ? EXPLANATION.sub("Use the card below if you'd like your coach to know.", "I haven't told your coach.") : EXPLANATION)
      end
      if message.to_s.match?(REMINDERS)
        reminder = reminder_answer(message)
        reminder = reminder.sub(" Nothing about your challenge has changed.", "") if parts.any?
        parts << reminder
      end
      parts.join(" ")
    end
  end
end
