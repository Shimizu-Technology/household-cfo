module SavingsChallenge
  # What a participant can do about the challenge itself, stated as the app
  # actually works: only the program team pauses a challenge, and there is no
  # participant control to leave one.
  module ParticipantHelp
    EXIT = /\b(?:pause|leave|quit|stop|cancel|withdraw(?: from)?|get out of|take a (?:pause|break) from|step (?:back|away) from)\s+(?:doing\s+)?(?:the\s+|this\s+|my\s+)?(?:savings\s+|bog\s+)?(?:challenge|program)\b/i
    ANSWER = "There isn't a pause button for you in the app. Only your program team can pause the challenge, so your coach is the person to ask about stepping back. What you've already recorded stays, and you don't need to check in or report anything today.".freeze

    def self.answer(message) = (ANSWER if message.to_s.match?(EXIT))
  end
end
