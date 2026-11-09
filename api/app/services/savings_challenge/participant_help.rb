module SavingsChallenge
  # What a participant can do about the challenge itself. Only the platform
  # can pause a challenge, for a whole cohort, so nothing here promises that.
  module ParticipantHelp
    EXIT = /\b(?:pause|leave|quit|stop|cancel|withdraw(?: from)?|get out of|take a (?:pause|break) from|step (?:back|away) from)\s+(?:doing\s+)?(?:the\s+|this\s+|my\s+)?(?:savings\s+|bog\s+)?(?:challenge|program)\b/i
    ANSWER = "You can't pause the challenge yourself in the app. Your program team would be the place to ask. You don't have to do anything in it today.".freeze

    def self.answer(message) = (ANSWER if message.to_s.match?(EXIT))
  end
end
