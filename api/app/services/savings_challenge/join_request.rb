module SavingsChallenge
  # "I want to join", "how do I join?", "sign me up". Reading only: the join
  # card in the chat carries the same terms and dates as the join screen, and
  # nothing happens until she accepts there.
  module JoinRequest
    JOIN = /\b(?:join|enrol+|sign(?:\s+me)?\s+up|take\s+part|participate|get\s+(?:me\s+)?in(?:to)?|count\s+me\s+in|opt\s+in)\b/i.freeze
    LEAVE = /\b(?:quit|leave|drop\s+out|cancel|opt\s+out|unenrol+|withdraw|stop\s+(?:the|my)|pause)\b/i.freeze
    CHALLENGE_WORDS = /\b(?:challenge|program|programme|group|savings|90|ninety|bank\s+of\s+guam|bog)\b/i.freeze
    PERSONAL = /\b(?:i|we|me|us|can|how|where|want|wanna|like|let['’]?s|please|ready)\b/i.freeze
    BARE = /\A(?:(?:ok(?:ay)?|hi|hey|mia|so)[,!\s]+)*(?:i\s+(?:want|would\s+like|['’]d\s+like|wanna)\s+to\s+(?:join|sign\s+up|enrol+)|i\s+want\s+in|(?:can|may)\s+i\s+(?:join|sign\s+up|enrol+)|how\s+(?:do|can)\s+(?:i|we)\s+(?:join|sign\s+up|enrol+|get\s+in)|(?:please\s+)?sign\s+me\s+up|(?:please\s+)?enrol+\s+me|let['’]?s\s+join|count\s+me\s+in|join(?:\s+(?:now|please))?|i['’]?m\s+ready\s+to\s+join)(?:\s+(?:please|now|today|thanks))?[?.!\s]*\z/i.freeze

    def self.matches?(message)
      text = message.to_s.squish
      return false if text.length > 240 || text.match?(LEAVE)
      return false if text.match?(/\b(?:friend|sister|brother|mom|mother|dad|father|husband|wife|coworker|co-worker|someone|somebody)\b/i)

      text.match?(BARE) || (text.match?(JOIN) && text.match?(PERSONAL) && text.match?(CHALLENGE_WORDS))
    end

    def self.range_text(starts_on, ends_on)
      "#{starts_on.strftime('%b %-d')} to #{ends_on.strftime('%b %-d')}"
    end
  end
end
