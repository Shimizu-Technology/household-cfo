module SavingsChallenge
  # What a participant can do about the challenge itself, stated as the app
  # actually works: only the program team pauses a challenge, and there is no
  # participant control to leave one.
  module ParticipantHelp
    EXIT = /\b(?:pause|leave|quit|stop|cancel|withdraw(?: from)?|take a break from|step (?:back|away) from)\b[^.!?]{0,40}\b(?:challenge|program)\b/i
    ANSWER = "There isn't a pause button for you in the app. Only your program team can pause or end the challenge for you, so your coach is the person to ask. What you've already recorded stays, and you don't need to check in or report anything today.".freeze

    def self.answer(message) = (ANSWER if message.to_s.match?(EXIT))
  end
end
