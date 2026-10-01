# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

    STRUCTURED_PROHIBITION_FIELD = :structured_prohibition
    PHRASE_ARTIFACT_FIELD = :phrase_artifact

    HUMAN_GROUP_PATTERN = /(?:
      people|persons?|families|women|men|households|communities|residents|citizens|locals|
      mothers|fathers|parents|children|elders|workers|students|couples
    )/ix.freeze
    PLACE_PATTERN = /(?:the\s+)?[[:alpha:]][[:alpha:].'’\-]*(?:\s+[[:alpha:]][[:alpha:].'’\-]*){0,3}/i.freeze
    DEMOGRAPHIC_TERM_PATTERN = /(?!(?:human|individual|participant|client|user)\b)[[:alpha:]'’\-]{3,}(?:ians?|eans?|icans?|inos?|ese|ish|anders?|landers?|orros?|ans?|erners?|inx)/i.freeze
    PROPER_IDENTITY_PATTERN = /(?-i:(?!(?:The|Use|Give|Make|Match|Mirror|Copy|Adopt|Write|Talk|Speak|Reply|Answer|Sound|Choose|Channel|Example|Reviewed|Community|Participant|Coach|Assistant|Mia|Approved|Exact|Plain|Warm|Direct|Respectful)\b)[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2})/.freeze
    QUALIFIED_GROUP_PATTERNS = [
      /\b#{HUMAN_GROUP_PATTERN}\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}\b/ix,
      /\b#{HUMAN_GROUP_PATTERN}\s+(?:(?:who|that)\s+)?(?:live|lives|living|reside|resides|residing)\s+(?:in|on)\s+#{PLACE_PATTERN}\b/ix,
      /\b(?:(?!(?:our|their|all|some|these|those|participating|enrolled)\b)[[:alpha:]'’\-]+\s+){1,3}#{HUMAN_GROUP_PATTERN}\b/ix,
      /\b(?:a|an|every|all)\s+#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i
    ].freeze

    RESPONSE_STYLE_PATTERN = /\b(?:
      voice|tone|style|accent|dialect|slang|vernacular|language|phrasing|expressions?|idioms?|lingo|
      cadence|drawl|speech|speech\s+patterns?|colloquialisms?|rhythm|sound|speak|talk|write|
      respond|reply|answer|wording|communication\s+style|traditions?|values?|customs?|cultural\s+identity|cultural\s+traits?
    )\b/ix.freeze
    IDENTITY_BASIS_PATTERNS = [
      /\b(?:locals?|regional|cultural|community[\s-]specific|island(?:[\s-]style)?)\b/i,
      /\b(?:location|locale|region|address|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:locals?|residents?|people|families|users|participants)\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}\s+(?:locals?|residents?|people|families|users|participants)\b/x,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b(?:southern|northern|eastern|western)\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}[\s-]*(?:style|#{RESPONSE_STYLE_PATTERN})\b/x,
      /\b#{RESPONSE_STYLE_PATTERN}\s+(?:of|from|for|like|based\s+on)\s+#{PLACE_PATTERN}\b/ix
    ].freeze

    FINANCIAL_CLAIM_PATTERN = /\b(?:
      money|finances?|financial|budget\w*|sav(?:e|es|ed|ing|ings|ers?)|(?:over|under)?spend\w*|debt|borrow\w*|
      invest\w*|remit\w*|income|salary|wealth|cash|credit|payments?|bills?|afford\w*|funds?
    )\b/ix.freeze
    CONCRETE_REALITY_PATTERN = /\b(?:
      eligible|eligibility|subject\s+to|regulation|tax|insurance|coverage|costs?|fees?|freight|
      shipping|calendar|deadline|access|availability|storm|hurricane|typhoon|emergency|disaster|preparation|
      automatic\s+transfers?|program\s+survey|study|published\s+data|official\s+guidance
    )\b/ix.freeze
    JUDGMENT_PATTERN = /\b(?:
      irresponsible|careless|reckless|wasteful|illiterate|undisciplined|bad|good|better|worse|poor\s+habits?|
      too\s+much|don['’]?t\s+know|do\s+not\s+know|always|never|the\s+same\s+way|prioriti[sz]\w*\b.{0,50}\bover
    )\b/ix.freeze

    class << self
      def violations(value, field: :instruction, identity_labels: [])
        return [] if field.in?([ STRUCTURED_PROHIBITION_FIELD, :metadata ])

        text = value.to_s.unicode_normalize(:nfkc)
        violations = []
        unless field == PHRASE_ARTIFACT_FIELD
          violations << LOCATION_DERIVED_PERSONA if identity_based_response_style?(text, field:, identity_labels:)
        end
        if demographic_financial_claim?(text) && !concrete_nonjudgmental_reality?(text)
          violations << REGIONAL_STEREOTYPE
        end
        violations.uniq
      end

      private

      def identity_based_response_style?(text, field:, identity_labels:)
        identity_basis = IDENTITY_BASIS_PATTERNS.any? { |pattern| text.match?(pattern) } ||
          Array(identity_labels).any? { |label| label.present? && text.match?(/\b#{Regexp.escape(label)}\b/i) }
        return identity_basis if field == :style_instruction

        text.match?(RESPONSE_STYLE_PATTERN) && identity_basis
      end

      def demographic_financial_claim?(text)
        (text.match?(FINANCIAL_CLAIM_PATTERN) || text.match?(JUDGMENT_PATTERN)) &&
          QUALIFIED_GROUP_PATTERNS.any? { |pattern| text.match?(pattern) }
      end

      def concrete_nonjudgmental_reality?(text)
        text.match?(CONCRETE_REALITY_PATTERN) && !text.match?(JUDGMENT_PATTERN)
      end
    end
  end
end
