# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

    NEGATION_PATTERN = /(?:do not|don['’]t|never|must not|should not|shouldn['’]t|cannot|can not|can['’]t|avoid|without)/i.freeze
    GROUP_NOUN_PATTERN = /(?:people|families|women|men|households|clients|participants|communities)/i.freeze
    LOCATION_GROUP_PATTERN = /#{GROUP_NOUN_PATTERN}\s+(?:from|in)\s+(?:the\s+)?[[:alpha:]][[:alpha:].'’\- ]{1,80}/i.freeze
    PROPER_DESCRIPTOR_GROUP_PATTERN = /[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2}\s+#{GROUP_NOUN_PATTERN}/.freeze
    DEMONYM_DESCRIPTOR_GROUP_PATTERN = /(?:(?!human\b|individual\b|specific\b|participating\b|enrolled\b)[[:alpha:]'’\-]+\s+){0,2}[[:alpha:]'’\-]*(?:ian|an|ese|ish|ino|ican|ern|orro|esian)\s+#{GROUP_NOUN_PATTERN}/i.freeze
    REGIONAL_GROUP_PATTERN = /(?:#{LOCATION_GROUP_PATTERN}|#{PROPER_DESCRIPTOR_GROUP_PATTERN}|#{DEMONYM_DESCRIPTOR_GROUP_PATTERN})/.freeze
    STANDALONE_DEMONYM_PATTERN = /(?:Guamanians?|Southerners?|Chamorro(?:s|\s+people)?|Puerto\s+Ricans?|(?:North|South|East|West)erners)/i.freeze
    REGIONAL_SUBJECT_PATTERN = /(?:#{REGIONAL_GROUP_PATTERN}|#{STANDALONE_DEMONYM_PATTERN})/.freeze
    REGIONAL_GENERALIZATION_PATTERNS = [
      /\b#{REGIONAL_SUBJECT_PATTERN}\s+(?:always|never|typically|usually|often|naturally|inherently|generally|as\s+a\s+rule|tend\s+to)\b/i,
      /\b#{REGIONAL_SUBJECT_PATTERN}\s+(?:are|is)\b/i
    ].freeze
    USE_INFERRED_LANGUAGE_PATTERN = /\buse\w*\b(?:(?!\b(?:without|not)\b).){0,60}\b(?:accent|dialect|slang|vernacular)\b/i
    LOCATION_DERIVED_PERSONA_PATTERNS = [
      /\b(?:sound|talk|speak|write|respond)\b.{0,50}\b(?:like|as)\s+(?:someone|a\s+person|people|locals?)\s+(?:from|in)\b/i,
      /\b(?:talk|speak|write|respond)\b.{0,30}\b(?:the\s+way|like)\s+locals?\s+(?:do\s+)?(?:from|in)\b/i,
      /\b(?:imitat\w*|cop(?:y|ies|ied|ying)|fak\w*|invent\w*|generat\w*|adopt\w*)\b.{0,50}\b(?:accent|dialect|slang|vernacular)\b/i,
      USE_INFERRED_LANGUAGE_PATTERN,
      /\b(?:infer|assume|invent|generate|assign)\w*\b.{0,90}\b(?:culture|cultural\s+(?:identity|style|traits?|values?|beliefs?|customs?|traditions?)|regional\s+(?:style|traits?)|local\s+values?|values?|beliefs?|customs?|traditions?)\b/i,
      /\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,100}\b(?:cultural?|regional|local)?\s*(?:style|voice|language|phrasing|tone|identity|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b.{0,100}\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity)\b.{0,100}\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,80}\b(?:style|voice|language|phrasing|tone|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b/i
    ].freeze
    PARTICIPANT_LED_LANGUAGE_PATTERN = /\b(?:participant|user|client)['’]?s?\s+(?:own\s+)?(?:words|language|phrasing|slang|dialect)\b.{0,100}\b(?:explicitly\s+)?(?:supplied|used|requested|chosen|shared|provided)\b/i

    class << self
      def violations(value, field: :instruction)
        text = value.to_s.unicode_normalize(:nfkc)
        violations = []
        violations << REGIONAL_STEREOTYPE if unnegated_pattern?(text, REGIONAL_GENERALIZATION_PATTERNS)
        location_patterns = LOCATION_DERIVED_PERSONA_PATTERNS
        if participant_led_language?(text) || respectful_reference_title?(text, field)
          location_patterns = location_patterns - [ USE_INFERRED_LANGUAGE_PATTERN ]
        end
        if unnegated_pattern?(text, location_patterns)
          violations << LOCATION_DERIVED_PERSONA
        end
        violations.uniq
      end

      private

      def participant_led_language?(text)
        text.match?(PARTICIPANT_LED_LANGUAGE_PATTERN)
      end

      def respectful_reference_title?(text, field)
        field == :reference_title && text.match?(/\Ahow\s+to\s+use\b.{0,80}\brespectfully\z/i)
      end

      def unnegated_pattern?(text, patterns)
        patterns.any? do |pattern|
          text.to_enum(:scan, pattern).any? do
            match = Regexp.last_match
            !negated?(text[0...match.begin(0)].to_s.last(160), patterns)
          end
        end
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
