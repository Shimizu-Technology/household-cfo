# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

    NEGATION_PATTERN = /(?:do not|don['’]t|never|must not|should not|shouldn['’]t|cannot|can not|can['’]t|avoid|without)/i.freeze
    GROUP_NOUN_PATTERN = /(?:people|families|women|men|households|clients|participants|communities|residents|citizens|locals)/i.freeze
    LOCATION_GROUP_PATTERN = /#{GROUP_NOUN_PATTERN}\s+(?:of|from|in|on)\s+(?:the\s+)?[[:alpha:]][[:alpha:].'’\- ]{1,80}/i.freeze
    RESIDENCE_GROUP_PATTERN = /#{GROUP_NOUN_PATTERN}\s+who\s+(?:live|reside)\s+(?:in|on)\s+(?:the\s+)?[[:alpha:]][[:alpha:].'’\- ]{1,80}/i.freeze
    PROPER_DESCRIPTOR_GROUP_PATTERN = /[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2}\s+#{GROUP_NOUN_PATTERN}/.freeze
    DEMONYM_DESCRIPTOR_GROUP_PATTERN = /(?:(?!human\b|individual\b|specific\b|participating\b|enrolled\b)[[:alpha:]'’\-]+\s+){0,2}[[:alpha:]'’\-]*(?:ian|an|ese|ish|ino|ican|ern|orro|esian)\s+#{GROUP_NOUN_PATTERN}/i.freeze
    REGIONAL_GROUP_PATTERN = /(?:#{LOCATION_GROUP_PATTERN}|#{RESIDENCE_GROUP_PATTERN}|#{PROPER_DESCRIPTOR_GROUP_PATTERN}|#{DEMONYM_DESCRIPTOR_GROUP_PATTERN})/.freeze
    STANDALONE_DEMONYM_PATTERN = /(?:
      [[:alpha:]'’\-]*(?:ians|eans|icans|inos|ese|ish|landers)
      |Guamanians?
      |Southerners?
      |Chamorro(?:s|\s+people)?
      |Puerto\s+Ricans?
      |Islanders?
      |(?:North|South|East|West)erners
    )/ix.freeze
    REGIONAL_SUBJECT_PATTERN = /(?:#{REGIONAL_GROUP_PATTERN}|#{STANDALONE_DEMONYM_PATTERN})/.freeze
    REGIONAL_GENERALIZATION_PATTERNS = [
      /\b#{REGIONAL_SUBJECT_PATTERN}\s+(?:always|never|typically|usually|often|naturally|inherently|generally|as\s+a\s+rule|tend\s+to)\b/i,
      /\b#{REGIONAL_SUBJECT_PATTERN}\s+(?:are|is)\b/i
    ].freeze
    USE_INFERRED_LANGUAGE_PATTERN = /\buse\w*\b(?:(?!\b(?:without|not)\b).){0,60}\b(?:accent|dialect|slang|vernacular)\b/i
    RESIDENCE_MIRRORING_PATTERN = /\b(?:mirror|copy|match|imitate)\w*\b.{0,50}\b(?:the\s+way|how)\s+(?:people|participants|residents|locals?)\s+(?:speak|talk|write)\b.{0,60}\b(?:where\s+they\s+live|where\s+they(?:'|’)re\s+from|in\s+their\s+(?:location|locale|region|community))\b/i
    LOCALIZED_LANGUAGE_PATTERN = /\b(?:use|adopt|add|sprinkle|choose)\w*\b.{0,70}\b(?:island(?:[\s-]*style)?|local|regional|cultural)\s+(?:language|expressions?|phrasing|voice|tone|slang|dialect|vernacular)\b.{0,70}\b(?:for|from|in|based\s+on)\b.{0,50}\b(?:people|participants|residents|locals?|families|households|Guam|Puerto\s+Rico|the\s+South|location|locale|region)\b/i
    LOCATION_DERIVED_PERSONA_PATTERNS = [
      /\b(?:sound|talk|speak|write|respond)\b.{0,50}\b(?:like|as)\s+(?:someone|a\s+person|people|locals?)\s+(?:from|in)\b/i,
      /\b(?:talk|speak|write|respond)\b.{0,30}\b(?:the\s+way|like)\s+locals?\s+(?:do\s+)?(?:from|in)\b/i,
      /\b(?:imitat\w*|cop(?:y|ies|ied|ying)|fak\w*|invent\w*|generat\w*|adopt\w*)\b.{0,50}\b(?:accent|dialect|slang|vernacular)\b/i,
      USE_INFERRED_LANGUAGE_PATTERN,
      RESIDENCE_MIRRORING_PATTERN,
      LOCALIZED_LANGUAGE_PATTERN,
      /\b(?:infer|assume|invent|generate|assign)\w*\b.{0,90}\b(?:culture|cultural\s+(?:identity|style|traits?|values?|beliefs?|customs?|traditions?)|regional\s+(?:style|traits?)|local\s+values?|values?|beliefs?|customs?|traditions?)\b/i,
      /\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,100}\b(?:cultural?|regional|local)?\s*(?:style|voice|language|phrasing|tone|identity|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b.{0,100}\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity)\b.{0,100}\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,80}\b(?:style|voice|language|phrasing|tone|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b/i
    ].freeze
    LANGUAGE_SUPPLIER_PATTERN = /(?:participant|user|client|human\s+coach|coach(?:\s+[[:upper:]][[:alpha:]'’\-]+)?)['’]?s?/i.freeze
    LANGUAGE_MATERIAL_PATTERN = /(?:words?|language|phrasing|slang|dialect|expressions?|phrases?|vernacular)/i.freeze
    LANGUAGE_APPROVAL_PATTERN = /(?:explicitly\s+)?(?:supplied|used|requested|chosen|shared|provided|authored|approved)/i.freeze
    EXPLICITLY_SUPPLIED_LANGUAGE_PATTERN = /\b#{LANGUAGE_SUPPLIER_PATTERN}\b.{0,120}\b(?:#{LANGUAGE_MATERIAL_PATTERN}\b.{0,60}\b#{LANGUAGE_APPROVAL_PATTERN}|#{LANGUAGE_APPROVAL_PATTERN}\b.{0,60}\b#{LANGUAGE_MATERIAL_PATTERN})\b/i

    class << self
      def violations(value, field: :instruction)
        text = value.to_s.unicode_normalize(:nfkc)
        violations = []
        violations << REGIONAL_STEREOTYPE if unnegated_pattern?(text, REGIONAL_GENERALIZATION_PATTERNS)
        location_patterns = respectful_reference_title?(text, field) ? LOCATION_DERIVED_PERSONA_PATTERNS - [ USE_INFERRED_LANGUAGE_PATTERN ] : LOCATION_DERIVED_PERSONA_PATTERNS
        if unnegated_pattern?(
          text,
          location_patterns,
          explicitly_supplied_patterns: [ USE_INFERRED_LANGUAGE_PATTERN, LOCALIZED_LANGUAGE_PATTERN ]
        )
          violations << LOCATION_DERIVED_PERSONA
        end
        violations.uniq
      end

      private

      def respectful_reference_title?(text, field)
        field == :reference_title && text.match?(/\Ahow\s+to\s+use\b.{0,80}\brespectfully\z/i)
      end

      def unnegated_pattern?(text, patterns, explicitly_supplied_patterns: [])
        patterns.any? do |pattern|
          text.to_enum(:scan, pattern).any? do
            match = Regexp.last_match
            next false if explicitly_supplied_patterns.include?(pattern) && explicitly_supplied_for_match?(text, match)

            !negated?(text[0...match.begin(0)].to_s.last(160), patterns)
          end
        end
      end

      def explicitly_supplied_for_match?(text, match)
        text[match.begin(0), match[0].length + 140].to_s.match?(EXPLICITLY_SUPPLIED_LANGUAGE_PATTERN)
      end

      def negated?(prefix, related_patterns)
        return true if prefix.match?(/\b#{NEGATION_PATTERN}\b\s*(?:(?:make|let|have)\s+(?:mia|the\s+assistant|assistant)\s+)?\z/i)

        negation = prefix.to_enum(:scan, NEGATION_PATTERN).map { Regexp.last_match }.last
        return false unless negation

        suffix = prefix[negation.end(0)..]
        coordinated = suffix.match(/\A(?<prior_clause>.{1,100})\b(?:and|or)\s*\z/i)
        coordinated && related_patterns.any? { |pattern| coordinated[:prior_clause].match?(pattern) }
      end
    end
  end
end
