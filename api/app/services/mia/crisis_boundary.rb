module Mia
  class CrisisBoundary
    FIRST_PERSON_SELF_HARM_INTENT_SOURCE = "(?:i(?:['’]m|\\s+am)\\s+(?:going\\s+to|about\\s+to|planning\\s+to|thinking\\s+(?:about|of))|i\\s+(?:want|plan|intend)\\s+to)".freeze
    PATTERNS = [
      /\b(?:kill(?:ing)? myself|end(?:ing)? my life|tak(?:e|ing) my own life|end it all|want to die|suicidal|suicide|hurt(?:ing)? myself|harm(?:ing)? myself|self[-\s]?harm)\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+(?:shoot(?:ing)?|hang(?:ing)?|drown(?:ing)?|stab(?:bing)?|poison(?:ing)?|suffocat(?:e|ing))\s+myself\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+overdos(?:e|ing)\b/i,
      /\bi\s+wish\s+i\s+(?:were|was)\s+(?:dead|not alive)\b|\bi(?:['’]d|\s+would)\s+rather\s+be\s+dead\b/i,
      /\b(?:don['’]?t|do not) want to (?:be alive|live(?: anymore)?|keep living)\b/i,
      /\b(?:don['’]?t|do not) think I can (?:keep living|go on)\b/i,
      /\b(?:can['’]?t|cannot) go on(?:[.!?,;:]|\z|\s+(?:anymore|living|like this|with (?:my )?life|with this anymore)\b)/i,
      /\b(?:can['’]?t|cannot) go on\s+with\s+(?:this|the|my)?\s*(?:debt|bills?|money stress)\b.*\banymore\b/i,
      /\b(?:everyone|everybody|they|my (?:family|kids|wife|husband|partner))(?:\s+would|['’]d)?\s+(?:be\s+)?better off without me\b/i
    ].freeze
    # Hopeless language that is not a stated plan to self-harm. Mia keeps helping
    # with the money question but always adds a gentle safety check.
    HOPELESS_PATTERNS = [
      /\b(?:can['’]?t|cannot) (?:do|take|handle) (?:this|it)(?:\s+any\s?more|\s+much longer|\s*(?:[.!?,;]|\z))/i,
      /\bi(?:['’]m|\s+am)?\s+(?:just\s+)?(?:giving up|give up|want to give up|ready to give up)(?:\s+on\s+(?:everything|life|myself))?(?:\s*[.!?,;]|\s*\z)/i,
      /\b(?:i(?:['’]m|\s+am)?\s+(?:so\s+|just\s+)?(?:feel(?:ing)?\s+)?hopeless|feel(?:ing)?\s+(?:so\s+)?hopeless)\b/i,
      /\btired of (?:everything|living|it all|life|trying)\b/i,
      /\b(?:want to|wanna) disappear\b/i,
      /\b(?:what['’]?s the|what is the|there['’]?s no|is there any) point (?:anymore|in anything|in trying|in any of this|in living)\b/i
    ].freeze
    WELLBEING_CHECK = "If you ever feel like you might hurt yourself, please call or text 988 right now, or 911 in an emergency. You deserve support, and the money plan can wait until you have it."
    WELLBEING_OPENING = "I’m really glad you told me, and feeling this way does not make you a failure."

    def self.matches?(message)
      normalized = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    def self.hopeless?(message)
      normalized = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      !matches?(normalized) && HOPELESS_PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    # Adds an acknowledgement (when the reply has none) and the safety check to
    # any reply, model-written or scripted.
    def self.with_wellbeing_check(reply)
      text = reply.to_s
      return text if text.include?("988")

      acknowledged = text.match?(/\b(?:not (?:a|mean you are a) failure|glad you (?:told|said)|(?:so |really )?(?:heavy|hard)\b|sounds (?:exhausting|overwhelming))/i)
      [ (acknowledged ? nil : WELLBEING_OPENING), text, WELLBEING_CHECK ].compact_blank.join(" ")
    end

    def self.response
      RuntimePersona::FALLBACKS.fetch("crisis")
    end
  end
end
