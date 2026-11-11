module SavingsChallenge
  # What a participant can do about the challenge itself. Only the program can
  # pause or end one, so Mia explains that plainly and tells the coach the
  # participant asked. Nothing here changes the participant's challenge.
  module ParticipantHelp
    EXIT = /\b(?:paus(?:e|ing)|leav(?:e|ing)|quit(?:ting)?|stop(?:ping)?|cancel(?:l?ing)?|withdraw(?:ing)?(?: from)?|get(?:ting)? out of|tak(?:e|ing) a (?:pause|break) from|step(?:ping)? (?:back|away) from)\s+(?:doing\s+)?(?:the\s+|this\s+|my\s+)?(?:savings\s+|bog\s+)?(?:challenge|program)\b(?=\s*(?:[?.!,;…]|\z|(?:please|pls|for|today|now|but|and|tho|though|rn|early|already)\b))/i
    REMINDERS = /\b(?:reminders?|notifications?|alerts?)\b/i
    REMINDER_ANSWER = "You can change challenge reminders without leaving. Open Privacy & reminders and turn off the reminders you don't want. Nothing about your challenge has changed.".freeze
    TAKE_OUT = /\b(?:take me out(?: of (?:the |this |my )?(?:challenge|program))?|i(?:['’]m| am) done with (?:the|this|my) (?:challenge|program))(?=\s*(?:[?.!,;…]|\z|please\b|pls\b))/i
    # "How do I quit?" in the challenge chat has no other object to mean.
    EXIT_BARE = /\b(?:how (?:do|can|could|would|should) (?:i|we)|can (?:i|we)|(?:i|we) (?:(?:want|need|have) to|wanna)|i['’]?d like to|i['’]?m (?:thinking (?:about|of)|ready to)|let me)\s+(?:quit|leave|stop|pause|cancel|withdraw|drop out|opt out)(?:\s+(?:it|this|now|please|pls|tho|though|early|already))*\s*(?:[?.!,]|\z)/i
    MEANING = "Stepping away would stop your daily check-ins, and what you've already saved stays in your record.".freeze
    TOLD = "No judgment. You can't leave or pause the challenge yourself in the app yet, so I've let your coach know you asked. " \
      "#{MEANING} Nothing changes until your coach reaches out, so you don't have to do anything in the challenge today.".freeze
    NOT_TOLD = "No judgment. You can't leave or pause the challenge yourself in the app yet, and I couldn't reach your coach from here, so please tell them directly. " \
      "#{MEANING} Nothing changes until you do, so you don't have to do anything in the challenge today.".freeze

    DISCUSSION = /\b(?:(?:if|whether)\s+i|(?:i|we)\s+(?:don['’]?t|dont|do not)\s+want to)\s+(?:quit|leave|pause|stop|withdraw)(?=\s*(?:[?.!,;]|\z))/i
    REQUEST = /\A\s*(?:(?:hey|okay|ok|so|mia|seriously|please|pls)[,\s]+)*(?:(?:(?:can|could|would) you (?:please )?)?(?:tell|let) (?:my|the) coach (?:know )?(?:that )?)?(?:(?:(?:i|we) (?:(?:want|need|have) to|wanna)|i['’]?d like to|i would like to|i['’]?m ready to|let me|help me)\s+(?:quit|leave|stop|pause|cancel|withdraw|drop out|opt out|get out of|step away from|take a break from)\b|(?:i|we)(?:['’]m| am|['’]re| are)\s+(?:quitting|leaving|pausing|stopping|withdrawing from|stepping away from)\b|(?:take me out|quit|leave|stop|pause|cancel|withdraw from)\s+(?:the\s+|this\s+|my\s+)?(?:savings\s+)?(?:challenge|program)\b)/i
    CONSENT_VETO = /\b(?:(?:don['’]?t|dont|do not|never)\s+(?:tell|notify|let)\b|not sure|unsure|lol no|just kidding|changed my mind)\b/i
    DISCUSSION_ONLY = /\b(?:not|never|don['’]?t|dont|do not|wouldn['’]?t|wont|won['’]?t|if|whether|hypothetical|thinking|considering|should|might|why|explain|discuss|what happens|what would|unsure|not sure|lol no|how (?:do|can|could|would|should))\b|\bcan (?:i|we) (?:leave|pause|quit|stop|cancel|withdraw)\b/i
    EXPLANATION = "You can't leave or pause the challenge yourself in the app yet. #{MEANING} Nothing has changed. If you want to step away, I can let your coach know when you ask.".freeze

    def self.exit?(message) = message.to_s.match?(EXIT) || message.to_s.match?(EXIT_BARE) || message.to_s.match?(DISCUSSION) || message.to_s.match?(TAKE_OUT) || message.to_s.match?(REMINDERS)

    def self.exit_request_intent(message)
      text = message.to_s
      return unless exit?(text)
      return if text.match?(REMINDERS) || text.match?(CONSENT_VETO)

      clause = text.split(/[.!?;,]|\b(?:and|but)\b/i).find do |part|
        !part.match?(DISCUSSION_ONLY) && exit?(part) && (part.match?(REQUEST) || part.match?(/\A\s*(?:please\s+)?#{TAKE_OUT.source}/i))
      end
      return unless clause

      clause.match?(/\b(?:pause|break|step back)\b/i) ? :pause : :leave
    end

    def self.exit_requested?(message) = exit_request_intent(message).present?

    def self.reminder_answer(message)
      return REMINDER_ANSWER.sub("turn off the reminders you don't want", "turn on the reminders you want") if message.to_s.match?(/\b(?:turn on|enable|start|resume)\b/i)

      REMINDER_ANSWER
    end

    # The reply for a participant asking to leave or pause, after telling the coach
    # through the support inbox. It says "I've let your coach know" only when that happened.
    def self.exit_answer(message, household:, user:, membership:)
      return reminder_answer(message) if message.to_s.match?(REMINDERS)
      return unless exit?(message)
      return EXPLANATION unless exit_requested?(message)

      coach_told?(household: household, user: user, membership: membership) ? TOLD : NOT_TOLD
    end

    def self.coach_told?(household:, user:, membership:)
      SetupHelp::Participant.new(household, user: user, cohort_membership: membership).request_leave(idempotency_key: "mia-leave-#{SecureRandom.uuid}")
      true
    rescue StandardError => error
      Rails.logger.warn("[ParticipantHelp] coach not told: #{error.class}: #{error.message}")
      false
    end
  end
end
