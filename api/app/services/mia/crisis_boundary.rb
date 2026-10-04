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
      /\b(?:can['’]?t|cannot) go on\s+with\s+(?:this|the|my)?\s*(?:debt|bills?|money stress)\b.*\banymore\b/i
    ].freeze

    def self.matches?(message)
      normalized = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    def self.response
      RuntimePersona::FALLBACKS.fetch("crisis")
    end
  end
end
