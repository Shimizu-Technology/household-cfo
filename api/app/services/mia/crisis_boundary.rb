module Mia
  class CrisisBoundary
    PATTERNS = [
      /\b(?:kill(?:ing)? myself|end(?:ing)? my life|tak(?:e|ing) my own life|end it all|want to die|suicidal|suicide|hurt(?:ing)? myself|harm(?:ing)? myself|self[-\s]?harm)\b/i,
      /\b(?:don['’]?t|do not) want to (?:be alive|live anymore|keep living)\b/i,
      /\b(?:don['’]?t|do not) think I can (?:keep living|go on)\b/i,
      /\b(?:can['’]?t|cannot) go on(?:\s+(?:anymore|living|with (?:my )?life|with this anymore))?(?:[.!?,;:]|\z)/i,
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
