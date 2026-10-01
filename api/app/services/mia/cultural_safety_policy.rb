# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

    PHRASE_ARTIFACT_FIELD = :phrase_artifact

    HUMAN_GROUP_PATTERN = /(?:
      people|persons?|everyone|everybody|families|women|men|households|communities|residents|citizens|locals|
      mothers|fathers|parents|children|youth|elders|workers|students|couples|spouses
    )/ix.freeze
    PLACE_PATTERN = /(?:the\s+)?[[:alpha:]][[:alpha:].'’\-]*(?:\s+[[:alpha:]][[:alpha:].'’\-]*){0,3}/i.freeze
    DEMOGRAPHIC_TERM_PATTERN = /(?!(?:human|individual|participant|client|user)\b)[[:alpha:]'’\-]{3,}(?:ians?|eans?|icans?|inos?|ese|ish|anders?|landers?|orros?|ans?|erners?|inx)/i.freeze
    PROPER_IDENTITY_PATTERN = /(?-i:(?!(?:The|Use|Give|Make|Match|Mirror|Copy|Adopt|Write|Talk|Speak|Reply|Answer|Sound|Choose|Channel|Example|Reviewed|Community|Participant|Coach|Assistant|Mia|Approved|Exact|Plain|Warm|Direct|Respectful)\b)[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2})/.freeze
    QUALIFIED_GROUP_PATTERNS = [
      /\b#{HUMAN_GROUP_PATTERN}\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}\b/ix,
      /\b#{HUMAN_GROUP_PATTERN}\s+(?:(?:who|that)\s+)?(?:live|lives|living|reside|resides|residing)\s+(?:in|on)\s+#{PLACE_PATTERN}\b/ix,
      /\b(?:a|an|every|all)\s+#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i
    ].freeze

    RESPONSE_STYLE_PATTERN = /\b(?:
      voice|tone|style|accent|dialect|slang|vernacular|language|phrasing|expressions?|idioms?|lingo|
      cadence|drawl|speech|speech\s+patterns?|colloquialisms?|rhythm|sound|speak|talk|write|writing|written|read|
      respond|reply|answer|communicate|wording|character|personality|come\s+across|seem|evoke|homegrown|feel|flavou?r|vibes?|aesthetic|sensibility|spirit|energy|aura|communication\s+style|
      traditions?|values?|customs?|cultural\s+identity|cultural\s+traits?
    )\b/ix.freeze
    IDENTITY_BASIS_PATTERNS = [
      /\b(?:locals?|regional|cultural|community[\s-]specific|island(?:[\s-]style)?)\b/i,
      /\b(?:location|locale|region|address|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:locals?|residents?|people|families|users|participants|everyone|everybody)\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}\s+(?:locals?|residents?|people|families|users|participants)\b/x,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b(?:southern|northern|eastern|western)\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}[\s-]*(?:style|#{RESPONSE_STYLE_PATTERN})\b/x,
      /\b#{RESPONSE_STYLE_PATTERN}\s+(?:of|from|for|like|based\s+on)\s+#{PLACE_PATTERN}\b/ix,
      /\bas\s+(?:if|though)\s+(?:you(?:'re|\s+are|\s+were)?|the\s+assistant(?:\s+is|\s+were)?|mia(?:\s+is|\s+were)?)?.{0,30}\b(?:from|grew\s+up\s+in)\s+#{PLACE_PATTERN}\b/ix,
      /\bread\s+like\s+.{0,30}\b(?:came|comes)\s+from\s+#{PLACE_PATTERN}\b/ix,
      /\b(?:distinct\s+)?#{PLACE_PATTERN}\s+character\b/ix,
      /\bcome\s+across\s+as\s+(?:a\s+)?#{PLACE_PATTERN}\s+local\b/ix,
      /\bseem\s+like\s+.{0,30}\bwritten\s+in\s+#{PLACE_PATTERN}\b/ix,
      /\bcommunicate\s+the\s+way\s+#{PLACE_PATTERN}\s+residents?\s+would\b/ix,
      /\bevoke\s+#{PLACE_PATTERN}\b/ix,
      /\bhomegrown\s+(?:in|from)\s+#{PLACE_PATTERN}\b/ix
    ].freeze

    FINANCIAL_CLAIM_PATTERN = /\b(?:
      money|finances?|financial(?:ly)?|budget\w*|(?:under)?sav(?:e|es|ed|ing|ings|ers?)|(?:over|under)?spend\w*|debt|borrow\w*|
      invest\w*|remit\w*|income|salary|wealth|cash|credit|payments?|bills?|afford\w*|funds?
    )\b/ix.freeze
    CONCRETE_REALITY_PATTERN = /\b(?:
      eligible|eligibility|subject\s+to|regulation|tax|insurance|insured|fdic|institutions?|banks?|credit\s+unions?|coverage|costs?|fees?|freight|
      shipping|calendar|deadline|access|availability|storm|hurricane|typhoon|emergency|disaster|preparation|
      automatic\s+transfers?|program\s+survey|study|published\s+data|official\s+guidance
    )\b/ix.freeze
    JUDGMENT_PATTERN = /\b(?:
      irresponsible|careless|reckless|wasteful|illiterate|undisciplined|naive|bad|good|better|worse|poor\s+(?:habits?|savers?|financial\s+habits?)|
      too\s+much|don['’]?t\s+know|do\s+not\s+know|always|never|the\s+same\s+way|prioriti[sz]\w*\b.{0,50}\bover
    )\b/ix.freeze
    SAFE_GENERIC_GROUP_SUBJECT_PATTERN = /\A(?:(?:a|an|our|all|some|these|those|the|weekly)\s+)?(?:participants?|clients?|users?|people|persons?|famil(?:y|ies)|households?|parents?|couples?|class(?:es)?|workshops?|support\s+groups?)\z/i.freeze
    NONPERSON_SUBJECT_PATTERN = /\A(?:the\s+)?(?:budget|plan|approach|method|program|account|loan|debt|payment|cost|price|fee|rule|law|policy|institution|bank|credit\s+union|transfer|savings?|income|cash\s+flow|emergency\s+fund)\z/i.freeze
    GROUP_QUANTIFIER_PATTERN = /\A(?:a|an|every|each|all|most|many|some)\s+/i.freeze
    CLAIM_SIGNAL_PATTERN = /\b(?:
      is|are|was|were|isn['’]?t|aren['’]?t|wasn['’]?t|weren['’]?t|has|have|had|can|cannot|can['’]?t|could|should|would|
      always|usually|often|generally|typically|naturally|tend(?:s)?\s+to|lack\w*|wast\w*|struggl\w*|put|mak\w*|handl\w*|(?:mis)?manag\w*|prioriti[sz]\w*|
      (?:over|under)?spend\w*|(?:under)?sav(?:e|es|ed|ing)(?!s)|budget\w*|borrow\w*|remit\w*|invest\w*|earn\w*|afford\w*
    )\b/ix.freeze
    BEHAVIOR_JUDGMENT_PATTERN = /(?:
      \b(?:(?:over|under)?spend\w*|(?:under)?sav(?:e|es|ed|ing|ings|ers?)|budget\w*|wast\w*)\b|
      \b(?:cannot|can['’]?t|do\s+not|don['’]?t|does\s+not|doesn['’]?t)\s+manag\w*\s+(?:their\s+)?money\b|
      \bhandl\w*\s+(?:their\s+)?money\s+poorly\b|
      \black\w*\s+financial\s+literacy\b|
      \b(?:bad|poor)\s+(?:financial|money)\s+habits?\b|
      \bstruggl\w*\s+with\s+finances?\b|
      \b(?:mis)?manag\w*\s+(?:their\s+)?money\b|
      \bmak\w*\s+poor\s+financial\s+decisions?\b|
      \bput\w*\s+.{0,50}\bbefore\s+savings?\b|
      \bprioriti[sz]\w*\s+.{0,50}\bover\s+savings?\b
    )/ix.freeze
    IMPERATIVE_OR_FIRST_SECOND_PERSON_PATTERN = /\A(?:i|we|you|our|your|my|do\s+not|don['’]?t|never|avoid|automatically|silently|ask|apply|buy|compare|explain|give|help|invest|keep|make|name|put|recommend|review|sell|show|tell|teach|update|use)\b/i.freeze
    SAFE_PROGRAM_OUTCOME_PATTERN = /\A(?:(?:a|an|these|those|the|weekly)\s+)?(?:class(?:es)?|workshops?|support\s+groups?)\b.{0,60}\b(?:help|teach|support)\w*\s+(?:participants?|clients?|users?|people|persons?|famil(?:y|ies)|households?)\b/i.freeze

    class << self
      def violations(value, field: :instruction, identity_labels: [])
        return [] if field == :metadata

        text = value.to_s.unicode_normalize(:nfkc)
        violations = []
        unless field == PHRASE_ARTIFACT_FIELD
          violations << LOCATION_DERIVED_PERSONA if identity_based_response_style?(text, field:, identity_labels:)
        end
        if claim_clauses(text).any? { |clause| demographic_financial_claim?(clause) && !concrete_nonjudgmental_reality?(clause) }
          violations << REGIONAL_STEREOTYPE
        end
        violations.uniq
      end

      def factual_local_reality?(value)
        text = value.to_s.unicode_normalize(:nfkc)
        claim_clauses(text).present? && claim_clauses(text).all? do |clause|
          clause.match?(CONCRETE_REALITY_PATTERN) &&
            !identity_based_response_style?(clause, field: :local_reality, identity_labels: []) &&
            !(demographic_financial_claim?(clause) && !concrete_nonjudgmental_reality?(clause))
        end
      end

      private

      def identity_based_response_style?(text, field:, identity_labels:)
        identity_basis = IDENTITY_BASIS_PATTERNS.any? { |pattern| text.match?(pattern) } ||
          Array(identity_labels).any? { |label| label.present? && text.match?(/\b#{Regexp.escape(label)}\b/i) }
        return identity_basis if field == :style_instruction

        text.match?(RESPONSE_STYLE_PATTERN) && identity_basis
      end

      def demographic_financial_claim?(text)
        return false unless text.match?(FINANCIAL_CLAIM_PATTERN) || text.match?(JUDGMENT_PATTERN)

        QUALIFIED_GROUP_PATTERNS.any? { |pattern| text.match?(pattern) } || arbitrary_group_claim?(text)
      end

      def concrete_nonjudgmental_reality?(text)
        text.match?(CONCRETE_REALITY_PATTERN) &&
          !text.match?(JUDGMENT_PATTERN) &&
          !text.match?(BEHAVIOR_JUDGMENT_PATTERN)
      end

      def arbitrary_group_claim?(text)
        clause = text.sub(/\A\s*(?:when\s+it\s+comes\s+to|with|regarding)\s+(?:money|finances?),\s*/i, "")
        return false if clause.match?(IMPERATIVE_OR_FIRST_SECOND_PERSON_PATTERN)
        return false if clause.match?(SAFE_PROGRAM_OUTCOME_PATTERN)

        marker = clause.match(CLAIM_SIGNAL_PATTERN)
        return false unless marker

        subject = clause[0...marker.begin(0)].to_s
          .sub(/[,\s]+\z/, "")
          .strip
        return false if subject.blank? || subject.match?(SAFE_GENERIC_GROUP_SUBJECT_PATTERN)

        normalized = subject.sub(GROUP_QUANTIFIER_PATTERN, "").strip
        words = normalized.scan(/[[:alnum:]'’\-]+/)
        return false unless words.length.between?(1, 6)
        return false if normalized.match?(NONPERSON_SUBJECT_PATTERN)

        normalized.match?(/\A(?:the|that|a|an|every|each)\b/i) ||
          normalized.match?(/\b#{HUMAN_GROUP_PATTERN}\z/ix) ||
          normalized.match?(/\b#{DEMOGRAPHIC_TERM_PATTERN}\z/i) ||
          words.last.match?(/s\z/i) ||
          normalized.match?(/\Agen\s+[[:alnum:]]+\z/i)
      end

      def claim_clauses(text)
        normalized = text.gsub(/\s+/, " ").strip
        normalized = normalized.gsub(/[.!?;]\s+(?=(?:they|he|she|it)\b)/i, " ")
        normalized.split(/(?<!\bMrs)(?<!\bMr)(?<!\bMs)(?<!\bDr)[.!?;]+/i).map(&:strip).reject(&:blank?)
      end
    end
  end
end
