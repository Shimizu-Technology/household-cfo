module SavingsChallenge
  # What a participant can do about the challenge itself. Only the program can
  # pause or end one, so Mia explains that plainly and tells the coach the
  # participant asked. Nothing here changes the participant's challenge.
  module ParticipantHelp
    EXIT = /\b(?:paus(?:e|ing)|leav(?:e|ing)|quit(?:ting)?|stop(?:ping)?|cancel(?:l?ing)?|withdraw(?:ing)?(?: from)?|get(?:ting)? out of|tak(?:e|ing) a (?:pause|break) from|step(?:ping)? (?:back|away) from)\s+(?:doing\s+)?(?:the\s+|this\s+|my\s+)?(?:savings\s+|bog\s+)?(?:challenge|program)\b(?=\s*(?:[?.!,;…]|\z|(?:please|pls|for|today|now|but|and|tho|though|rn|early|already)\b))/i
    REMINDERS = /\b(?:reminders?|notifications?|alerts?)\b/i
    REMINDER_ANSWER = "You can change challenge reminders without leaving. Open Privacy & reminders and turn off the reminders you don't want. Nothing about your challenge has changed.".freeze
    TAKE_OUT = /\b(?:take me out(?: of (?:the |this |my )?(?:challenge|program))?|i(?:['’]m| am) done with (?:the|this|my) (?:challenge|program))(?=\s*(?:[?.!,;…]|\z))/i
    # "How do I quit?" in the challenge chat has no other object to mean.
    EXIT_BARE = /\b(?:how (?:do|can|could|would|should) (?:i|we)|can (?:i|we)|(?:i|we) (?:(?:want|need|have) to|wanna)|i['’]?d like to|i['’]?m (?:thinking (?:about|of)|ready to)|let me)\s+(?:quit|leave|stop|pause|cancel|withdraw|drop out|opt out)(?:\s+(?:it|this|now|please|pls|tho|though|early|already))*\s*(?:[?.!,]|\z)/i
    MEANING = "Stepping away would stop your daily check-ins, and what you've already saved stays in your record.".freeze
    TOLD = "No judgment. You can't leave or pause the challenge yourself in the app yet, so I've let your coach know you asked. " \
      "#{MEANING} Nothing changes until your coach reaches out, so you don't have to do anything in the challenge today.".freeze
    NOT_TOLD = "No judgment. You can't leave or pause the challenge yourself in the app yet, and I couldn't reach your coach from here, so please tell them directly. " \
      "#{MEANING} Nothing changes until you do, so you don't have to do anything in the challenge today.".freeze

    DISCUSSION = /\b(?:(?:if|whether)\s+i|(?:i|we)\s+(?:don['’]?t|dont|do not)\s+want to)\s+(?:quit|leave|pause|stop|withdraw)(?=\s*(?:[?.!,;]|\z))/i
    REQUEST = /\A\s*(?:(?:hey|okay|ok|so|mia|seriously|please|pls)[,\s]+)*(?:(?:(?:can|could|would) you (?:please )?)?(?:tell|let) (?:my|the) coach (?:know )?(?:that )?)?(?:(?:how (?:do|can) (?:i|we)|can (?:i|we)|(?:i|we) (?:(?:want|need|have) to|wanna)|i['’]?d like to|i would like to|i['’]?m ready to|let me|help me)\s+(?:quit|leave|stop|pause|cancel|withdraw|drop out|opt out|get out of|step away from|take a break from)\b|(?:i|we)(?:['’]m| am|['’]re| are)\s+(?:quitting|leaving|pausing|stopping|withdrawing from|stepping away from)\b|(?:take me out|quit|leave|stop|pause|cancel|withdraw from)\s+(?:the\s+|this\s+|my\s+)?(?:savings\s+)?(?:challenge|program)\b)/i
    DISCUSSION_ONLY = /\b(?:not|never|don['’]?t|dont|do not|wouldn['’]?t|wont|won['’]?t|if|whether|hypothetical|thinking|considering|should|might|why|explain|discuss|what happens|what would|unsure|not sure|lol no)\b|\bcan (?:i|we) (?:leave|pause|quit|stop|cancel|withdraw)\b/i
    EXPLANATION = "You can't leave or pause the challenge yourself in the app yet. #{MEANING} Nothing has changed. If you want to step away, I can let your coach know when you ask.".freeze

    def self.exit?(message) = message.to_s.match?(EXIT) || message.to_s.match?(EXIT_BARE) || message.to_s.match?(DISCUSSION) || message.to_s.match?(TAKE_OUT) || message.to_s.match?(REMINDERS)

    def self.exit_requested?(message)
      text = message.to_s
      return false unless exit?(text)
      return false if text.match?(REMINDERS) || text.match?(DISCUSSION_ONLY)

      text.split(/[.!?;,]|\b(?:and|but)\b/i).any? do |clause|
        exit?(clause) && (clause.match?(REQUEST) || clause.match?(/\A\s*(?:please\s+)?#{TAKE_OUT.source}/i))
      end
    end

    # The reply for a participant asking to leave or pause, after telling the coach
    # through the support inbox. It says "I've let your coach know" only when that happened.
    def self.exit_answer(message, household:, user:, membership:)
      return REMINDER_ANSWER if message.to_s.match?(REMINDERS)
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
