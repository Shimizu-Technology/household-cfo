# frozen_string_literal: true

module Mia
  class LanguagePolicy
    CULTURAL_LANGUAGE_PATTERN = /\b(?:h[åa]fa adai|chelu|lanya|umbee(?:\s+gachong)?|biba)\b/i.freeze
    KNOWN_CULTURAL_PHRASES = [ "håfa adai", "hafa adai", "umbee gachong", "chelu", "lanya", "umbee", "biba" ].freeze
    APOSTROPHE_GRAPHEMES = [ "'", "’", "‘", "ʼ", "＇" ].freeze
    DASH_GRAPHEMES = [ "-", "‐", "‑", "‒", "–", "—", "―" ].freeze
    GREETING_PATTERN = /\b(?:h[åa]fa\s+adai|good\s+(?:morning|afternoon|evening))\b/i.freeze
    MILESTONE_PATTERN = /\b(?:
      paid\s+off|debt[-\s]?free|milestone|promotion|raise|bonus|windfall|unexpected\s+(?:win|income|money)|surprise\s+(?:win|income|money)|celebrat\w*|
      (?:reached|hit|met|achieved)\s+(?:my\s+|our\s+|the\s+)?(?:goal|target|milestone)|
      (?:saved|paid)\s+\$[\d,]+(?:\.\d{1,2})?
    )\b/ix.freeze
    EMOTIONAL_SUPPORT_PATTERN = /\b(?:ashamed|shame|overwhelmed|stressed|scared|afraid|fighting|panic|drowning)\b/i.freeze
    CRISIS_PATTERNS = [
      /\b(kill myself|end my life|want to die|suicidal|suicide|hurt myself|self[-\s]?harm)\b/i,
      /\b(?:can['’]?t|cannot) go on(?:\s+(?:anymore|living|with (?:my )?life))?(?:[.!?,;:]|\z)/i,
      /\b(?:can['’]?t|cannot) go on\s+with\s+(?:this|the|my)?\s*(?:debt|bills?|money stress)\b.*\banymore\b/i
    ].freeze
    STABLE_CONTEXT_IDS = {
      "greeting" => "greeting",
      "welcome" => "greeting",
      "milestone" => "milestone",
      "celebration" => "milestone",
      "emotional_support" => "emotional_support",
      "hard_moment" => "emotional_support",
      "repeated_pattern" => "repeated_pattern",
      "accountability" => "repeated_pattern",
      "known_bad_pattern" => "repeated_pattern",
      "routine" => "routine",
      "general" => "general",
      "crisis" => "crisis"
    }.freeze
    REPEATED_PATTERN = /\b(?:
      keep\s+(?:doing|spending|buying)|same\s+(?:thing|pattern)|every\s+time|
      (?:spent|spending|bought|buying|ordered|ordering|overdrew|overdrafted|missed|skipped|went\s+over|hit\s+(?:my\s+|the\s+)?(?:spending|credit|budget)\s+limit)\b.{0,40}\bagain|
      again\b.{0,40}\b(?:spent|spending|bought|buying|ordered|ordering|overdrew|overdrafted|missed|skipped|went\s+over)
    )\b/ix.freeze
    GENERIC_PRAISE_SENTENCE_PATTERN = /(?:\A|(?<=[.!?])\s+)(?:you(?:'re| are)\s+(?:doing\s+)?(?:great|amazing|awesome|incredible)|great\s+(?:job|work)|amazing\s+(?:job|work)|i(?:'m| am)\s+(?:so\s+)?proud\s+of\s+you|you(?:'ve| have)\s+got\s+this)[.!]?\s*/i.freeze

    def self.redact_unauthorized_phrase_artifacts(content, persona:)
      new(user_message: "", persona: persona).send(:redact_unauthorized_phrase_artifacts, content)
    end

    def initialize(user_message:, history: [], persona: Persona.default)
      @user_message = user_message.to_s
      @history = Array(history)
      @persona = persona
    end

    def sanitize(content)
      return sanitize_custom_persona(content) if custom_persona?

      culture_allowed = cultural_language_allowed? && !cultural_language_recently_used?
      value = culture_allowed ? content.to_s : remove_reflexive_cultural_opener(content.to_s)
      value = remove_generic_praise(value) unless earned_moment?
      value = remove_cultural_language(value) unless culture_allowed
      normalize(value)
    end

    def cultural_language_allowed?
      user_message.match?(CULTURAL_LANGUAGE_PATTERN) ||
        user_message.match?(GREETING_PATTERN) ||
        earned_moment? ||
        user_message.match?(EMOTIONAL_SUPPORT_PATTERN) ||
        user_message.match?(REPEATED_PATTERN)
    end

    private

    attr_reader :user_message, :history, :persona

    def custom_persona?
      persona.respond_to?(:version_id) && persona.version_id.present?
    end

    def sanitize_custom_persona(content)
      value = content.to_s
      value = remove_generic_praise(value) unless earned_moment?
      entries = all_cultural_phrases
      allowed_entries = cultural_phrases.select { |entry| custom_phrase_allowed?(entry) }
      leading_phrase_removed = false
      entries.each do |entry|
        next if allowed_entries.include?(entry)

        pattern = custom_phrase_pattern(entry.fetch("text"))
        leading_phrase_removed ||= leading_phrase?(value, pattern)
        value = value.gsub(pattern, " ")
      end
      value, known_leading_phrase_removed = remove_unapproved_known_cultural_language(value, allowed_entries)
      leading_phrase_removed ||= known_leading_phrase_removed
      if leading_phrase_removed && !value.strip.end_with?("?")
        value = value.sub(/\A\s*(should|can|could|need|will|may|might|have|are)\b/i, 'You \1')
      end
      normalize(value.gsub(/\s+([.!?,;:])/, "\\1"))
    end

    def cultural_phrases
      Array(persona.cultural_phrases).filter_map do |entry|
        normalized = entry.respond_to?(:stringify_keys) ? entry.stringify_keys : nil
        normalized if normalized&.fetch("text", nil).to_s.squish.present?
      end
    end

    def all_cultural_phrases
      source = persona.respond_to?(:all_cultural_phrases) ? persona.all_cultural_phrases : persona.cultural_phrases
      Array(source).filter_map do |entry|
        normalized = entry.respond_to?(:stringify_keys) ? entry.stringify_keys : nil
        normalized if normalized&.fetch("text", nil).to_s.squish.present?
      end
    end

    def redact_unauthorized_phrase_artifacts(content)
      authorized_entries = cultural_phrases
      value = content.to_s
      all_cultural_phrases.each do |entry|
        next if authorized_entries.include?(entry)

        value = value.gsub(custom_phrase_pattern(entry.fetch("text")), " ")
      end
      value.gsub(/\s+([.!?,;:])/, "\\1").squish
    end

    def custom_phrase_allowed?(entry)
      phrase = entry.fetch("text")
      return false if custom_phrase_recently_used?(phrase, entry.fetch("frequency", "sparing"))

      prohibited = Array(entry["prohibited_contexts"])
      return false if prohibited.any? { |context| context_matches?(context) }
      return true if user_message.match?(custom_phrase_pattern(phrase))

      allowed = Array(entry["allowed_contexts"])
      allowed.any? { |context| context_matches?(context) }
    end

    def context_matches?(context)
      case normalized_context_id(context)
      when "greeting" then user_message.match?(GREETING_PATTERN)
      when "milestone" then earned_moment?
      when "emotional_support" then user_message.match?(EMOTIONAL_SUPPORT_PATTERN)
      when "repeated_pattern" then user_message.match?(REPEATED_PATTERN)
      when "routine" then routine_moment?
      when "general" then true
      when "crisis" then crisis_moment?
      else false
      end
    end

    def normalized_context_id(context)
      value = context.to_s.downcase.squish
      stable_id = value.tr(" -", "_")
      return STABLE_CONTEXT_IDS.fetch(stable_id) if STABLE_CONTEXT_IDS.key?(stable_id)

      return "greeting" if value.match?(/greet|welcome/)
      return "milestone" if value.match?(/milestone|celebrat|achievement|surprise|windfall/)
      return "emotional_support" if value.match?(/emotion|support|stress|hard moment/)
      return "repeated_pattern" if value.match?(/repeat|accountab|known.bad|pattern/)
      return "routine" if value.match?(/routine|ordinary|warm|familiar|community/)
      return "general" if value.match?(/general|any.relevant|as needed|always|all contexts/)
      return "crisis" if value.match?(/crisis|self.harm|suicid/)

      nil
    end

    def routine_moment?
      !user_message.match?(GREETING_PATTERN) &&
        !earned_moment? &&
        !user_message.match?(EMOTIONAL_SUPPORT_PATTERN) &&
        !user_message.match?(REPEATED_PATTERN) &&
        !crisis_moment?
    end

    def crisis_moment?
      CRISIS_PATTERNS.any? { |pattern| user_message.match?(pattern) }
    end

    def custom_phrase_recently_used?(phrase, frequency)
      lookback = case frequency.to_s
      when "as_needed" then 2
      when "very_rare" then 6
      else 4
      end
      pattern = custom_phrase_pattern(phrase)
      assistant_history.last(lookback).any? { |message| message.match?(pattern) }
    end

    def custom_phrase_pattern(phrase)
      graphemes = phrase.to_s.squish.scan(/\X/)
      source = graphemes.map do |grapheme|
        if grapheme.match?(/\A[[:space:]]\z/)
          "[\\p{Space}\\u200B]+"
        elsif APOSTROPHE_GRAPHEMES.include?(grapheme)
          "[#{Regexp.escape(APOSTROPHE_GRAPHEMES.join)}]"
        elsif DASH_GRAPHEMES.include?(grapheme)
          "[\\p{Space}\\u200B]*[#{Regexp.escape(DASH_GRAPHEMES.join)}][\\p{Space}\\u200B]*"
        else
          variants = %i[nfc nfd nfkc nfkd].map { |form| Regexp.escape(grapheme.unicode_normalize(form)) }.uniq
          variants.one? ? variants.first : "(?:#{variants.join('|')})"
        end
      end.join
      /(?<![[:alnum:]_])#{source}(?![[:alnum:]_])/i
    end

    def remove_unapproved_known_cultural_language(content, allowed_entries)
      approved = allowed_entries.flat_map do |entry|
        KNOWN_CULTURAL_PHRASES.filter do |known_phrase|
          entry.fetch("text").match?(custom_phrase_pattern(known_phrase))
        end
      end.uniq

      leading_phrase_removed = false
      value = KNOWN_CULTURAL_PHRASES.reduce(content) do |current, known_phrase|
        next current if approved.include?(known_phrase)

        pattern = custom_phrase_pattern(known_phrase)
        leading_phrase_removed ||= leading_phrase?(current, pattern)
        current.gsub(pattern, " ")
      end
      [ value, leading_phrase_removed ]
    end

    def leading_phrase?(content, pattern)
      content.match?(/\A\s*#{pattern.source}/i)
    end

    def earned_moment?
      user_message.match?(MILESTONE_PATTERN)
    end

    def cultural_language_recently_used?
      assistant_history.last(4).any? { |message| message.match?(CULTURAL_LANGUAGE_PATTERN) }
    end

    def assistant_history
      history.filter_map do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"]
        content.to_s if role.to_s == "assistant"
      end
    end

    def remove_reflexive_cultural_opener(content)
      content.sub(
        /\A(?:(?:okay|got it|you got it),?\s+(?:chelu|lanya|umbee(?:\s+gachong)?)|h[åa]fa adai(?:,?\s+chelu)?|(?:chelu|lanya|umbee(?:\s+gachong)?))[.!,:-]?\s*/i,
        ""
      )
    end

    def remove_generic_praise(content)
      content.gsub(GENERIC_PRAISE_SENTENCE_PATTERN, " ")
    end

    def remove_cultural_language(content)
      content
        .gsub(/\s*,?\s*#{CULTURAL_LANGUAGE_PATTERN.source}\s*,?/i, " ")
        .gsub(/\s+([.!?,;:])/, "\\1")
    end

    def normalize(content)
      content
        .gsub(/[\r\n]+/, " ")
        .sub(/\A[\s,;:.-]+/, "")
        .squish
        .sub(/\A([[:lower:]])/) { |letter| letter.upcase }
        .gsub(/([.!?])\s+([[:lower:]])/) { "#{Regexp.last_match(1)} #{Regexp.last_match(2).upcase}" }
        .presence
    end
  end
end
