# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

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
      /\b(?:a|an|every|all)\s+#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i
    ].freeze

    RESPONSE_STYLE_PATTERN = /\b(?:
      voice|tone|style|accent|dialect|slang|vernacular|language|phrasing|expressions?|idioms?|lingo|
      cadence|drawl|speech|speech\s+patterns?|colloquialisms?|rhythm|sound|speak|talk|write|
      respond|reply|answer|wording|feel|flavou?r|vibes?|aesthetic|sensibility|spirit|energy|aura|communication\s+style|
      traditions?|values?|customs?|cultural\s+identity|cultural\s+traits?
    )\b/ix.freeze
    IDENTITY_BASIS_PATTERNS = [
      /\b(?:locals?|regional|cultural|community[\s-]specific|island(?:[\s-]style)?)\b/i,
      /\b(?:location|locale|region|address|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:locals?|residents?|people|families|users|participants)\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}\s+(?:locals?|residents?|people|families|users|participants)\b/x,
      /\b#{DEMOGRAPHIC_TERM_PATTERN}\b/i,
      /\b(?:southern|northern|eastern|western)\b/i,
      /\b#{PROPER_IDENTITY_PATTERN}[\s-]*(?:style|#{RESPONSE_STYLE_PATTERN})\b/x,
      /\b#{RESPONSE_STYLE_PATTERN}\s+(?:of|from|for|like|based\s+on)\s+#{PLACE_PATTERN}\b/ix,
      /\bas\s+(?:if|though)\s+(?:you(?:'re|\s+are|\s+were)?|the\s+assistant(?:\s+is|\s+were)?|mia(?:\s+is|\s+were)?)?.{0,30}\b(?:from|grew\s+up\s+in)\s+#{PLACE_PATTERN}\b/ix
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
    SAFE_GENERIC_GROUP_SUBJECT_PATTERN = /\A(?:(?:our|all|some|these|those|the|weekly)\s+)?(?:participants?|clients?|users?|people|persons?|famil(?:y|ies)|households?|parents?|couples?|classes|workshops|support\s+groups)\z/i.freeze
    NONPERSON_SUBJECT_PATTERN = /\A(?:the\s+)?(?:budget|plan|approach|method|program|account|loan|debt|payment|cost|price|fee|rule|law|policy|institution|bank|credit\s+union|transfer|savings?|income|cash\s+flow|emergency\s+fund)\z/i.freeze
    GROUP_QUANTIFIER_PATTERN = /\A(?:a|an|every|each|all|most|many|some)\s+/i.freeze
    CLAIM_PREDICATE_PATTERN = /(?:
      \b(?:always|usually|often|generally|typically|as\s+a\s+rule)\b\s*(?:,\s*)?(?:they\s+)?(?=
        (?:over|under)?spend\w*|(?:under)?sav(?:e|es|ed|ing|ings|ers?)|budget\w*|avoid\s+debt|carry\s+too\s+much\s+debt|have\s+too\s+much\s+debt|prioriti[sz]\w*
      )|
      \b(?:tend(?:s)?\s+to)\b\s*(?=
        (?:over|under)?spend\w*|(?:under)?sav(?:e|es|ed|ing|ings|ers?)|budget\w*|avoid\s+debt|be\s+(?:irresponsible|careless|reckless|wasteful|naive)
      )|
      \b(?:over|under)?spend\w*\b|
      \b(?:under)?sav(?:e|es|ed|ing)\b|
      \bbudget\w*\b|
      \bwast(?:e|es|ed|ing)\s+money\b|
      \b(?:avoid(?:\s+[[:alpha:]]+){0,3}|carry|have)\s+(?:too\s+much\s+)?debt\b|
      \bprioriti[sz]\w*\b.{0,60}\bover\b|
      \b(?:are|is|was|were|aren['’]?t|isn['’]?t|wasn['’]?t|weren['’]?t|seem|seems|remain|remains)\s+(?:not\s+)?(?:financially\s+)?(?:irresponsible|careless|reckless|wasteful|naive|bad|good|poor)\b|
      \b(?:are|is|was|were)\s+(?:naturally\s+)?(?:more|less)\s+disciplined\s+with\s+money\b|
      \b(?:are|is|was|were|aren['’]?t|isn['’]?t|wasn['’]?t|weren['’]?t)\s+(?:not\s+)?(?:naturally\s+)?(?:better|worse|good|responsible)\s+with\s+money\b|
      \b(?:have|has)\s+poor\s+financial\s+habits?\b|
      \bhandle\w*\s+money\s+the\s+same\s+way\b|
      \b(?:do\s+not|don['’]?t|does\s+not|doesn['’]?t)\s+know\s+how\s+to\s+budget\b|
      \b(?:financially\s+)?(?:irresponsible|careless|reckless|wasteful|naive)\b|
      \b(?:bad|poor)\s+(?:with\s+money|savers?|financial\s+habits?)\b
    )/ix.freeze
    TRAIT_BEHAVIOR_PATTERN = /\b(?:(?:over|under)?spend\w*|(?:under)?sav(?:e|es|ed|ing|ings|ers?)|budget\w*)\b/i.freeze
    IMPERATIVE_OR_FIRST_SECOND_PERSON_PATTERN = /\A(?:i|we|you|our|your|my|do\s+not|don['’]?t|never|avoid|automatically|silently|ask|apply|buy|compare|explain|give|help|invest|keep|make|name|put|recommend|review|sell|show|tell|teach|update|use)\b/i.freeze
    SAFE_PROGRAM_OUTCOME_PATTERN = /\A(?:(?:these|those|the|weekly)\s+)?(?:classes|workshops|support\s+groups)\b.{0,60}\b(?:help|teach|support)\w*\s+(?:participants?|clients?|users?|people|persons?|famil(?:y|ies)|households?)\b/i.freeze

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
        return false unless text.match?(CLAIM_PREDICATE_PATTERN)

        QUALIFIED_GROUP_PATTERNS.any? { |pattern| text.match?(pattern) } || arbitrary_group_claim?(text)
      end

      def concrete_nonjudgmental_reality?(text)
        text.match?(CONCRETE_REALITY_PATTERN) &&
          !text.match?(JUDGMENT_PATTERN) &&
          !text.match?(TRAIT_BEHAVIOR_PATTERN)
      end

      def arbitrary_group_claim?(text)
        clause = text.sub(/\A\s*(?:when\s+it\s+comes\s+to|with|regarding)\s+(?:money|finances?),\s*/i, "")
        return false if clause.match?(IMPERATIVE_OR_FIRST_SECOND_PERSON_PATTERN)
        return false if clause.match?(SAFE_PROGRAM_OUTCOME_PATTERN)

        marker = clause.match(CLAIM_PREDICATE_PATTERN)
        return false unless marker

        subject = clause[0...marker.begin(0)].to_s
          .sub(/[,\s]+\z/, "")
          .strip
        return false if subject.blank? || subject.match?(SAFE_GENERIC_GROUP_SUBJECT_PATTERN)

        normalized = subject.sub(GROUP_QUANTIFIER_PATTERN, "").strip
        words = normalized.scan(/[[:alnum:]'’\-]+/)
        words.length.between?(1, 5) && !normalized.match?(NONPERSON_SUBJECT_PATTERN)
      end

      def claim_clauses(text)
        normalized = text.gsub(/\s+/, " ").strip
        normalized = normalized.gsub(/[.!?;]\s+(?=(?:they|he|she|it)\b)/i, " ")
        normalized.split(/(?<!\bMrs)(?<!\bMr)(?<!\bMs)(?<!\bDr)[.!?;]+/i).map(&:strip).reject(&:blank?)
      end
    end
  end
end
