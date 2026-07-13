# frozen_string_literal: true

module Mia
  class LanguagePolicy
    CULTURAL_LANGUAGE_PATTERN = /\b(?:h[åa]fa adai|chelu|lanya|umbee(?:\s+gachong)?|biba)\b/i.freeze
    GREETING_PATTERN = /\b(?:h[åa]fa\s+adai|good\s+(?:morning|afternoon|evening))\b/i.freeze
    MILESTONE_PATTERN = /\b(?:
      paid\s+off|debt[-\s]?free|milestone|promotion|raise|bonus|windfall|unexpected\s+(?:win|income|money)|surprise\s+(?:win|income|money)|celebrat\w*|
      (?:reached|hit|met|achieved)\s+(?:my\s+|our\s+|the\s+)?(?:goal|target|milestone)|
      (?:saved|paid)\s+\$[\d,]+(?:\.\d{1,2})?
    )\b/ix.freeze
    EMOTIONAL_SUPPORT_PATTERN = /\b(?:ashamed|shame|overwhelmed|stressed|scared|afraid|fighting|panic|drowning)\b/i.freeze
    REPEATED_PATTERN = /\b(?:
      keep\s+(?:doing|spending|buying)|same\s+(?:thing|pattern)|every\s+time|
      (?:spent|spending|bought|buying|ordered|ordering|overdrew|overdrafted|missed|skipped|went\s+over|hit\s+(?:my\s+|the\s+)?(?:spending|credit|budget)\s+limit)\b.{0,40}\bagain|
      again\b.{0,40}\b(?:spent|spending|bought|buying|ordered|ordering|overdrew|overdrafted|missed|skipped|went\s+over)
    )\b/ix.freeze
    GENERIC_PRAISE_SENTENCE_PATTERN = /(?:\A|(?<=[.!?])\s+)(?:you(?:'re| are)\s+(?:doing\s+)?(?:great|amazing|awesome|incredible)|great\s+(?:job|work)|amazing\s+(?:job|work)|i(?:'m| am)\s+(?:so\s+)?proud\s+of\s+you|you(?:'ve| have)\s+got\s+this)[.!]?\s*/i.freeze

    def initialize(user_message:, history: [])
      @user_message = user_message.to_s
      @history = Array(history)
    end

    def sanitize(content)
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

    attr_reader :user_message, :history

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
