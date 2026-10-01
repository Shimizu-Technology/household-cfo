# frozen_string_literal: true

module Mia
  class CulturalSafetyPolicy
    REGIONAL_STEREOTYPE = :regional_stereotype
    LOCATION_DERIVED_PERSONA = :location_derived_persona

    NEGATION_PATTERN = /(?:do not|don['’]t|never|must not|should not|shouldn['’]t|cannot|can not|can['’]t|avoid|without)/i.freeze

    HUMAN_GROUP_NOUN_PATTERN = /(?:
      people|persons?|families|women|men|households|clients|participants|communities|
      residents|citizens|locals|users|members|mothers|fathers|parents|children|elders|
      workers|students|couples|savers|spenders
    )/ix.freeze
    PLACE_PATTERN = /(?:the\s+)?[[:alpha:]][[:alpha:].'’\-]*(?:\s+[[:alpha:]][[:alpha:].'’\-]*){0,4}/i.freeze
    LOCATED_GROUP_PATTERN = /#{HUMAN_GROUP_NOUN_PATTERN}\s+(?:of|from|in|on)\s+#{PLACE_PATTERN}/ix.freeze
    RESIDENCE_GROUP_PATTERN = /#{HUMAN_GROUP_NOUN_PATTERN}\s+(?:(?:who|that)\s+)?(?:live|lives|living|reside|resides|residing)\s+(?:in|on)\s+#{PLACE_PATTERN}/ix.freeze
    IDENTITY_DESCRIPTOR_GROUP_PATTERN = /(?:(?!human\b|individual\b|specific\b|participating\b|enrolled\b)[[:alpha:]'’\-]+\s+){0,2}[[:alpha:]'’\-]*(?:ian|an|ese|ish|ino|ican|ern|orro|esian)\s+#{HUMAN_GROUP_NOUN_PATTERN}/i.freeze
    CULTURAL_DESCRIPTOR_GROUP_PATTERN = /(?:(?!(?:human|individual|specific|participating|enrolled|some|these|those|all|our|their)\b)[[:alpha:]'’\-]+\s+){1,3}#{HUMAN_GROUP_NOUN_PATTERN}/i.freeze
    DEMOGRAPHIC_TERM_PATTERN = /[[:alpha:]'’\-]{3,}(?:ians?|eans?|icans?|inos?|ese|ish|anders?|landers?|orros?|ans?|erners?)/i.freeze
    QUANTIFIED_IDENTITY_PATTERN = /(?:a|an|every|all)\s+(?:#{DEMOGRAPHIC_TERM_PATTERN}|(?-i:[[:upper:]][[:alpha:]'’\-]{2,}))/x.freeze
    GROUP_SUBJECT_PATTERN = /(?:
      #{LOCATED_GROUP_PATTERN}|
      #{RESIDENCE_GROUP_PATTERN}|
      #{IDENTITY_DESCRIPTOR_GROUP_PATTERN}|
      #{CULTURAL_DESCRIPTOR_GROUP_PATTERN}|
      #{DEMOGRAPHIC_TERM_PATTERN}|
      #{QUANTIFIED_IDENTITY_PATTERN}
    )/x.freeze

    GENERALIZING_QUALIFIER_PATTERN = /(?:always|never|typically|usually|often|naturally|inherently|generally|as\s+a\s+rule|tend(?:s)?\s+to)/i.freeze
    ASSUMED_BEHAVIOR_PATTERN = /(?:
      over[\s-]*spend\w*|under[\s-]*save\w*|
      (?:spend\w*|sav(?:e|es|ed|ing))\b.{0,40}\b(?:more|less|the\s+same\s+way)|
      avoid\w*(?:\s+\w+){0,5}\s+(?:debt|discussing?\s+debt|talking?\s+about\s+debt)|
      prioriti[sz]\w*\b.{0,60}\bover\b|
      (?:handle\w*|manage\w*|budget\w*)\b.{0,50}\bthe\s+same\s+way|
      (?:do(?:es)?n['’]?t|do(?:es)?\s+not)\s+know\s+how\s+to\s+budget|
      (?:have|has|carry|carries)\s+too\s+much\s+debt|
      wast(?:e|es|ed|ing)\s+(?:their\s+)?money
    )/ix.freeze
    EVALUATIVE_TRAIT_PATTERN = /(?:
      (?:financially\s+)?(?:irresponsible|careless|reckless|wasteful|undisciplined|illiterate)|
      (?:not\s+)?(?:bad|good|better|worse)\s+(?:with\s+(?:money|finances?|debt|budgets?|budgeting)|at\s+(?:saving|budgeting)|savers?|spenders?)|
      (?:frugal|cheap|savvy|disciplined|literate)\s+(?:with\s+(?:money|finances?|debt|budgets?|budgeting))|
      (?:not\s+|aren['’]?t\s+|isn['’]?t\s+)?responsible\s+(?:with\s+(?:money|finances?|debt|budgets?|budgeting))|
      (?:have|has)\s+(?:poor|bad|unhealthy)\s+financial\s+habits
    )/ix.freeze
    REGIONAL_GENERALIZATION_PATTERNS = [
      /\b#{GROUP_SUBJECT_PATTERN}\s*(?:,\s*)?(?:#{GENERALIZING_QUALIFIER_PATTERN}\s*,?\s*)?#{ASSUMED_BEHAVIOR_PATTERN}\b/ix,
      /\b#{GROUP_SUBJECT_PATTERN}\s+(?:(?:are|is)\s+)?(?:(?:naturally|inherently)\s+)?#{EVALUATIVE_TRAIT_PATTERN}\b/ix,
      /\b#{GROUP_SUBJECT_PATTERN}\s*[:?.!]\s*(?:they\s+)?(?:#{GENERALIZING_QUALIFIER_PATTERN}\s*,?\s*)?(?:they\s+)?#{ASSUMED_BEHAVIOR_PATTERN}\b/ix
    ].freeze

    VOICE_ACTION_PATTERN = /(?:use|adopt|add|sprinkle|choose|match|mirror|copy|imitate|reflect|model|write|speak|talk|respond|reply|answer|sound|give|make|channel)/i.freeze
    SPEECH_MATERIAL_PATTERN = /(?:language|expressions?|phrasing|phrases?|voice|tone|slang|dialect|vernacular|speech(?:\s+patterns?)?|words?|accent|colloquialisms?|idioms?|lingo|cadence|drawl)/i.freeze
    REGIONAL_SPEECH_PATTERN = /(?:
      (?:local|regional|cultural|island(?:[\s-]*style)?|(?-i:[[:upper:]][[:alpha:]'’\-]+[\s-]*style))\s+#{SPEECH_MATERIAL_PATTERN}|
      (?:the\s+)?(?:way|how)\s+(?:(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+)?(?:locals?|residents?|people|participants|users)\s+(?:talk|speak|write)|
      (?:the\s+)?(?:way|like)\s+locals?\s+(?:do\s+)?(?:from|in)\s+#{PLACE_PATTERN}|
      (?-i:[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2})\s+(?:locals?|residents?|people)['’]?s?\s+#{SPEECH_MATERIAL_PATTERN}|
      (?-i:[[:upper:]][[:alpha:]'’\-]+(?:\s+[[:upper:]][[:alpha:]'’\-]+){0,2})(?:[\s-]*style)?\s+#{SPEECH_MATERIAL_PATTERN}|
      (?:southern|northern|eastern|western|island)\s+#{SPEECH_MATERIAL_PATTERN}|
      #{SPEECH_MATERIAL_PATTERN}\s+(?:from|of)\s+#{PLACE_PATTERN}|
      sound\s+local\s+to\s+#{PLACE_PATTERN}|
      #{SPEECH_MATERIAL_PATTERN}\s+(?:based\s+on|from|according\s+to)\s+(?:a\s+)?(?:home\s+)?(?:address|location|locale|region|identity)
    )/ix.freeze
    REGIONAL_SPEECH_DIRECTIVE_PATTERN = /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,120}\b#{REGIONAL_SPEECH_PATTERN}\b/ix.freeze
    REGIONAL_SPEECH_REVERSED_PATTERN = /\b#{REGIONAL_SPEECH_PATTERN}\b.{0,100}\b#{VOICE_ACTION_PATTERN}\w*\b/ix.freeze
    REGIONAL_PERSON_IMITATION_PATTERN = /\b(?:sound|talk|speak|write|respond|reply|answer|channel)\w*\b.{0,60}\b(?:like|as|how)\s+(?:(?:someone|a\s+person|people|locals?)\s+(?:from|in)\s+#{PLACE_PATTERN}|an?\s+(?:#{DEMOGRAPHIC_TERM_PATTERN}|(?:north|south|east|west)erner)|(?:#{DEMOGRAPHIC_TERM_PATTERN}|(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+locals?)\s+(?:speak|talk)?)\b/ix.freeze
    SPLIT_LOCATION_VOICE_PATTERN = /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,40}\b#{SPEECH_MATERIAL_PATTERN}\b\s*[.!?;]\s*(?:base|derive|set|choose)\w*\b.{0,40}\b(?:participant['’]s\s+)?(?:[[:upper:]][[:alpha:]'’\-]+\s+)?(?:address|location|locale|region|identity)\b/i.freeze
    SPLIT_REGIONAL_IMITATION_PATTERN = /\b#{VOICE_ACTION_PATTERN}\w*\b[^.!?;]{0,60}[.!?;]\s*(?:make|have|let)\w*\b.{0,50}\b(?:sound|talk|speak|write)\b.{0,30}\b(?:like\s+)?(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+locals?\b/i.freeze
    REGIONAL_AUDIENCE_VOICE_PATTERNS = [
      /\b(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+(?:users|participants|clients|residents)\b.{0,50}\bshould\s+(?:sound|talk|speak|write)\s+local\b/i,
      /\bfor\s+(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+(?:users|participants|clients|residents)\b.{0,60}\b#{VOICE_ACTION_PATTERN}\w*\b.{0,40}\b#{SPEECH_MATERIAL_PATTERN}\s+local\b/i,
      /\b(?:reply|answer|response)\b.{0,30}\bshould\s+(?:have|use)\b.{0,20}\b(?-i:[[:upper:]][[:alpha:]'’\-]+)\s+#{SPEECH_MATERIAL_PATTERN}\b/i,
      /\b(?:talk|speak|write|respond|reply|answer)\w*\b.{0,20}\b(?-i:[[:upper:]][[:alpha:]'’\-]+)[\s-]*style\b/i
    ].freeze
    FABRICATED_LANGUAGE_PATTERN = /\b(?:imitat\w*|cop(?:y|ies|ied|ying)|fak\w*|invent\w*|generat\w*)\b.{0,60}\b(?:accent|dialect|slang|vernacular)\b/i.freeze
    LOCATION_TRAIT_INFERENCE_PATTERNS = [
      /\b(?:infer|assume|invent|generate|assign)\w*\b.{0,90}\b(?:culture|cultural\s+(?:identity|style|traits?|values?|beliefs?|customs?|traditions?)|regional\s+(?:style|traits?)|local\s+values?|values?|beliefs?|customs?|traditions?)\b/i,
      /\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,100}\b(?:cultural?|regional|local)?\s*(?:style|voice|language|phrasing|tone|identity|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b.{0,100}\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity|where\s+(?:they|the\s+participant)\s+(?:live|are\s+from))\b/i,
      /\b(?:based\s+on|from|using|according\s+to)\b.{0,40}\b(?:home\s+)?(?:address|location|locale|region|identity)\b.{0,100}\b(?:match|adapt|tailor|change|set|choose|assign|infer|assume|generate|invent)\w*\b.{0,80}\b(?:style|voice|language|phrasing|tone|traits?|values?|beliefs?|customs?|traditions?|dialect|slang)\b/i
    ].freeze
    LOCATION_DERIVED_PERSONA_PATTERNS = [
      REGIONAL_SPEECH_DIRECTIVE_PATTERN,
      REGIONAL_SPEECH_REVERSED_PATTERN,
      REGIONAL_PERSON_IMITATION_PATTERN,
      SPLIT_LOCATION_VOICE_PATTERN,
      SPLIT_REGIONAL_IMITATION_PATTERN,
      *REGIONAL_AUDIENCE_VOICE_PATTERNS,
      FABRICATED_LANGUAGE_PATTERN,
      *LOCATION_TRAIT_INFERENCE_PATTERNS
    ].freeze

    LANGUAGE_SUPPLIER_PATTERN = /(?:participant|user|client|human\s+coach|coach(?:\s+[[:upper:]][[:alpha:]'’\-]+)?)/i.freeze
    LANGUAGE_MATERIAL_PATTERN = /(?:words?|language|phrasing|slang|dialect|expressions?|phrases?|vernacular)/i.freeze
    LANGUAGE_APPROVAL_PATTERN = /(?:explicitly\s+)?(?:supplied|used|requested|chosen|shared|provided|authored|approved)/i.freeze
    SUPPLIED_LANGUAGE_DIRECTIVE_PATTERNS = [
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,20}\b(?:the\s+exact\s+)?coach[\s-]+(?:approved|authorized)\s+(?:(?:local|regional|cultural|(?-i:[[:upper:]][[:alpha:]'’\-]+))\s+)?#{LANGUAGE_MATERIAL_PATTERN}\b/i,
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,20}\b(?:local\s+|regional\s+|cultural\s+)?#{LANGUAGE_MATERIAL_PATTERN}\b\s+from\s+(?:the\s+)?(?:approved|authorized)\s+coach\s+(?:glossary|guide|curriculum|reference|library)\b/i,
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,30}\b#{LANGUAGE_SUPPLIER_PATTERN}['’]s\b.{0,20}\b(?:own\s+)?#{LANGUAGE_MATERIAL_PATTERN}\b.{0,80}\b#{LANGUAGE_APPROVAL_PATTERN}\b/i,
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,30}\b#{LANGUAGE_SUPPLIER_PATTERN}['’]s\b.{0,20}\b#{LANGUAGE_APPROVAL_PATTERN}\b.{0,20}\b#{LANGUAGE_MATERIAL_PATTERN}\b/i,
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,20}\b#{LANGUAGE_MATERIAL_PATTERN}\b.{0,50}\b#{LANGUAGE_APPROVAL_PATTERN}\s+by\s+(?:the\s+)?#{LANGUAGE_SUPPLIER_PATTERN}\b/i,
      /\b#{VOICE_ACTION_PATTERN}\w*\b.{0,20}\b#{LANGUAGE_MATERIAL_PATTERN}\b\s+(?:(?:that|which)\s+)?(?:the\s+)?#{LANGUAGE_SUPPLIER_PATTERN}\b\s+#{LANGUAGE_APPROVAL_PATTERN}\b/i
    ].freeze

    class << self
      def violations(value, field: :instruction)
        text = value.to_s.unicode_normalize(:nfkc)
        violations = []
        violations << REGIONAL_STEREOTYPE if unnegated_pattern?(text, REGIONAL_GENERALIZATION_PATTERNS)
        violations << LOCATION_DERIVED_PERSONA if location_derived_persona?(text, field)
        violations.uniq
      end

      private

      def location_derived_persona?(text, field)
        return false if respectful_reference_title?(text, field)

        unnegated_pattern?(text, LOCATION_DERIVED_PERSONA_PATTERNS, allow_supplied_language: true)
      end

      def respectful_reference_title?(text, field)
        field == :reference_title && text.match?(/\Ahow\s+to\s+use\b.{0,80}\brespectfully\z/i)
      end

      def unnegated_pattern?(text, patterns, allow_supplied_language: false)
        patterns.any? do |pattern|
          text.to_enum(:scan, pattern).any? do
            match = Regexp.last_match
            next false if allow_supplied_language && supplied_language_directive_for_match?(text, match)
            next false if allow_supplied_language && prohibited_example_for_match?(text, match)

            !negated?(text[0...match.begin(0)].to_s.last(160), patterns)
          end
        end
      end

      def supplied_language_directive_for_match?(text, match)
        prior_boundary = text.rindex(/[.!?;\n]/, match.begin(0) - 1) unless match.begin(0).zero?
        start = prior_boundary ? prior_boundary + 1 : 0
        finish = text.index(/[.!?;\n]/, match.end(0)) || text.length
        sentence = text[start...finish]

        SUPPLIED_LANGUAGE_DIRECTIVE_PATTERNS.any? do |pattern|
          sentence.to_enum(:scan, pattern).any? do
            supplied = Regexp.last_match
            supplied_start = start + supplied.begin(0)
            supplied_finish = start + supplied.end(0)
            supplied_start <= match.begin(0) && supplied_finish >= match.end(0)
          end
        end
      end

      def prohibited_example_for_match?(text, match)
        opening_index, closing_index = enclosing_quote_indexes(text, match)
        return false unless opening_index && closing_index

        context_start = [ opening_index - 100, 0 ].max
        context_finish = [ closing_index + 180, text.length ].min
        context = text[context_start...context_finish]
        descriptive = context.match?(/\b(?:example|illustration|wrote|quoted|prohibited|forbidden)\b/i)
        prohibited = context.match?(
          /\b(?:prohibited|forbidden|(?:must|should)\s+not\s+(?:do|use|follow|repeat|say|write|adopt|imitate)|do\s+not\s+(?:use|follow|repeat|say|write|adopt|imitate)|never\s+(?:use|follow|repeat|say|write|adopt|imitate)|avoid\s+(?:using|following|repeating|saying|writing|adopting|imitating))\b/i
        )
        encouraged = context.match?(
          /\b(?:not\s+(?:prohibited|forbidden)|should\s+be\s+followed|example\s+to\s+follow|do\s+not\s+ignore)\b/i
        )
        descriptive && prohibited && !encouraged
      end

      def enclosing_quote_indexes(text, match)
        [ [ "‘", "’" ], [ "“", "”" ], [ '"', '"' ], [ "'", "'" ], [ "`", "`" ] ].each do |opening, closing|
          opening_index = text.rindex(opening, match.begin(0) - 1)
          next unless opening_index

          closing_index = text.index(closing, match.end(0))
          return [ opening_index, closing_index ] if closing_index
        end

        nil
      end

      def negated?(prefix, related_patterns)
        return true if prefix.match?(
          /\b#{NEGATION_PATTERN}\b(?:\s+(?:ever|at\s+any\s+time|in\s+any\s+case|under\s+any\s+circumstances))*\s*(?:(?:make|let|have)\s+(?:mia|the\s+assistant|assistant)\s+)?\z/i
        )

        negation = prefix.to_enum(:scan, NEGATION_PATTERN).map { Regexp.last_match }.last
        return false unless negation

        suffix = prefix[negation.end(0)..]
        coordinated = suffix.match(/\A(?<prior_clause>.{1,100})\b(?:and|or)\s*\z/i)
        coordinated && related_patterns.any? { |pattern| coordinated[:prior_clause].match?(pattern) }
      end
    end
  end
end
