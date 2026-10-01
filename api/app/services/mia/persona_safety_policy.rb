# frozen_string_literal: true

module Mia
  class PersonaSafetyPolicy
    VERSION = 5
    NEGATION_PATTERN = /(?:do not|don['’]t|never|must not|cannot|can['’]t|avoid|without)/i.freeze
    FORBIDDEN_KEY_PATTERN = /(?:\A|[_-])(?:raw[_-])?(?:prompt|system|developer|tool|model|write[_-]authority|write[_-]permissions?|permissions?|guardrails?|safety)(?:[_-]|\z)/i
    ASSISTANT_IDENTITY_PATTERN = /\b(?:digital|ai|artificial intelligence|virtual|automated)(?:[-\s]+[[:alpha:]]+){0,3}[-\s]+assistant\b/i
    CONCEALED_IDENTITY_PATTERNS = [
      /\b(?:never|do not|don['’]t|must not|avoid)\b.{0,50}\b(?:say|tell|mention|disclose|reveal|admit|identify)\b.{0,50}\b(?:ai|artificial intelligence|digital|virtual|automated)\b/i,
      /\b(?:hide|conceal|withhold|omit|deny|disguise)\b.{0,80}\b(?:ai|artificial intelligence|digital|virtual|automated|bot)\b/i,
      /\b(?:claim|say|tell|insist|imply|pretend)\b.{0,80}\b(?:not\s+(?:an?\s+)?(?:ai|artificial intelligence|digital|virtual|automated|bot)|(?:a\s+)?(?:real\s+)?human)\b/i,
      /\b(?:i am|i['’]m|this is)\s+(?:the\s+)?(?:human\s+)?coach\b/i,
      /\b(?:pretend|pose|pass)\s+(?:to be|as)\s+(?:the\s+)?(?:human\s+)?coach\b/i,
      /\b(?:impersonat\w*|masquerad\w*(?:\s+as)?)\s+(?:the\s+)?(?:human\s+)?coach\b/i,
      /\b(?:speak|write|respond)\s+as\s+(?:the\s+)?(?:human\s+)?coach\b/i,
      /\b(?:make|let|have)\b.{0,50}\b(?:participants?|users?|clients?|people|them)\b.{0,50}\b(?:believe|think|assume)\b.{0,50}\b(?:human|coach)\b/i
    ].freeze
    FORBIDDEN_GUIDANCE_PATTERNS = [
      /\b(?:ignore|disregard|override)\b.{0,80}\b(?:previous|system|developer|instruction|safety|guardrail|policy)\b/i,
      /\b(?:reveal|show|print|repeat|expose)\b.{0,50}\b(?:system prompt|developer message|hidden instruction|tool call)\b/i,
      /\b(?:system prompt|developer message|tool call|function call|write authority|write permission|read[\s-]*write access)\b/i,
      /\b(?:bypass|disable|remove|weaken)\b.{0,50}\b(?:safety|guardrail|policy|restriction|approval)\b/i,
      /\b(?:you are now|act as)\b/i,
      /\b(?:call|invoke|execute)\b.{0,40}\b(?:tool|function|command|api)\b/i,
      /\b(?:may|can|should)\b.{0,30}\b(?:write|create|update|delete|approve)\b.{0,50}\b(?:record|database|account|transaction|budget|household)\b/i,
      /\b(?:crisis protocol|crisis response|self[\s-]*harm|suicide|988|licensed advice)\b/i
    ].freeze
    FORBIDDEN_FINANCIAL_GUIDANCE = [
      {
        pattern: /\b(?:recommend|pick|name|select)\b.{0,60}\b(?:specific|individual)?\s*(?:stocks?|securities?|funds?|investments?)\b/i,
        message: "contains a directive to recommend specific investments"
      },
      {
        pattern: /\b(?:tell|instruct|direct|recommend|advise)\b.{0,100}\b(?:exactly|specific(?:ally)?)\s+(?:how much|what amount)\b.{0,60}\b(?:invest|buy|sell|allocate)\b/i,
        message: "contains a directive to prescribe a specific investment amount"
      },
      {
        pattern: /\b(?:provide|give|offer|deliver)\b.{0,60}\b(?:financial|legal|tax|investment|accounting)\s+advice\b/i,
        message: "contains a directive to provide licensed financial, legal, tax, investment, or accounting advice"
      },
      {
        pattern: /\b(?:tell|instruct|urge|advise|direct|recommend|encourage)\b.{0,100}\b(?:buy|sell|invest|move|transfer|put|place|convert|allocate|stake|borrow|bet)\b.{0,100}\b(?:bitcoin|btc|crypto(?:currency)?|ethereum|eth|meme\s*coin|nft|options?|forex|futures?|leveraged\s+(?:fund|etf)|penny\s+stocks?|individual\s+stocks?)\b/i,
        message: "contains a directive to move money into a risky asset"
      },
      {
        pattern: /\b(?:buy|sell|invest|move|transfer|put|place|convert|allocate|stake|borrow|bet)\b.{0,100}\b(?:bitcoin|btc|crypto(?:currency)?|ethereum|eth|meme\s*coin|nft|options?|forex|futures?|leveraged\s+(?:fund|etf)|penny\s+stocks?)\b/i,
        message: "contains a directive to move money into a risky asset"
      },
      {
        pattern: /\b(?:guarantee(?:d)?|promise)\b.{0,80}\b(?:returns?|profits?|gains?|income|outcomes?|results?)\b|\b(?:returns?|profits?|gains?|income|outcomes?|results?)\b.{0,80}\b(?:are\s+)?guaranteed\b/i,
        message: "promises or guarantees financial returns or outcomes"
      }
    ].freeze

    class UnsafeConfiguration < ArgumentError
      attr_reader :errors

      def initialize(errors)
        @errors = errors.freeze
        super(errors.join(", "))
      end
    end

    class << self
      def validate!(configuration)
        errors = violations(configuration)
        raise UnsafeConfiguration, errors if errors.any?

        true
      end

      def violations(configuration)
        errors = []
        validate_identity_disclosure(configuration, errors)
        walk(configuration, "$", errors, human_coach_name(configuration))
        errors.uniq.first(20)
      end

      private

      def validate_identity_disclosure(configuration, errors)
        identity = configuration.is_a?(Hash) ? configuration["identity"] || configuration[:identity] : nil
        return unless identity.is_a?(Hash)

        assistant_name = identity["assistant_name"] || identity[:assistant_name]
        human_coach_name = identity["human_coach_name"] || identity[:human_coach_name]
        if assistant_name.is_a?(String) && human_coach_name.is_a?(String) && assistant_name.casecmp?(human_coach_name)
          errors << "$.identity.assistant_name cannot be the same as the human coach's name"
        end
        validate_identity_field(
          identity["assistant_relationship"] || identity[:assistant_relationship],
          "$.identity.assistant_relationship",
          errors
        )
        validate_identity_field(identity["disclosure"] || identity[:disclosure], "$.identity.disclosure", errors)
      end

      def validate_identity_field(value, path, errors)
        return unless value.is_a?(String)

        unless value.match?(ASSISTANT_IDENTITY_PATTERN)
          errors << "#{path} must clearly identify the persona as a digital or AI assistant"
        end
      end

      def human_coach_name(configuration)
        identity = configuration.is_a?(Hash) ? configuration["identity"] || configuration[:identity] : nil
        return unless identity.is_a?(Hash)

        identity["human_coach_name"] || identity[:human_coach_name]
      end

      def claims_human_coach_identity?(value, human_coach_name)
        return false unless human_coach_name.is_a?(String) && human_coach_name.strip.present?

        pattern = human_coach_identity_pattern(human_coach_name)
        related_patterns = CONCEALED_IDENTITY_PATTERNS + [ pattern ]

        unnegated_match?(value, pattern, related_patterns: related_patterns)
      end

      def walk(value, path, errors, human_coach_name)
        case value
        when Hash
          value.each do |key, child|
            key_name = key.to_s
            errors << "#{path}.#{key_name} is a reserved configuration key" if key_name.match?(FORBIDDEN_KEY_PATTERN)
            walk(child, "#{path}.#{key_name}", errors, human_coach_name)
          end
        when Array
          value.each_with_index { |child, index| walk(child, "#{path}[#{index}]", errors, human_coach_name) }
        when String
          if identity_misrepresentation?(value, human_coach_name)
            errors << "#{path} cannot impersonate the human coach or conceal the assistant's AI identity"
          end
          errors << "#{path} contains safety or prompt-control guidance" if FORBIDDEN_GUIDANCE_PATTERNS.any? { |pattern| value.match?(pattern) }
          cultural_violations = CulturalSafetyPolicy.violations(value, field: cultural_field_for(path))
          if cultural_violations.include?(CulturalSafetyPolicy::REGIONAL_STEREOTYPE)
            errors << "#{path} contains a regional or cultural stereotype"
          end
          if cultural_violations.include?(CulturalSafetyPolicy::LOCATION_DERIVED_PERSONA)
            errors << "#{path} cannot infer dialect, slang, or cultural traits from a location or identity label"
          end
          financial_patterns = FORBIDDEN_FINANCIAL_GUIDANCE.map { |rule| rule.fetch(:pattern) }
          FORBIDDEN_FINANCIAL_GUIDANCE.each do |rule|
            if unnegated_match?(value, rule.fetch(:pattern), related_patterns: financial_patterns)
              errors << "#{path} #{rule.fetch(:message)}"
            end
          end
        end
      end

      def identity_misrepresentation?(value, human_coach_name)
        related_patterns = CONCEALED_IDENTITY_PATTERNS.dup
        related_patterns << human_coach_identity_pattern(human_coach_name) if human_coach_name.is_a?(String) && human_coach_name.strip.present?

        CONCEALED_IDENTITY_PATTERNS.any? do |pattern|
          unnegated_match?(value, pattern, related_patterns: related_patterns)
        end ||
          claims_human_coach_identity?(value, human_coach_name)
      end

      def cultural_field_for(path)
        return :reference_title if path.match?(/\A\$\.curriculum\.(?:guidance|scripts)\[\d+\]\.title\z/)
        return :reference_title if path.match?(/\A\$\.culture\.references\[\d+\]\z/)

        :instruction
      end

      def human_coach_identity_pattern(human_coach_name)
        /\b(?:(?:i am|i['’]m|this is|you are|you['’]re|identify yourself as|present yourself as|claim to be|pretend to be|speak as|write as|respond as|masquerade as)\s+(?:the\s+)?|impersonate\s+)#{Regexp.escape(human_coach_name.strip)}\b/i
      end

      def unnegated_match?(value, pattern, related_patterns: [ pattern ])
        value.to_enum(:scan, pattern).any? do
          match = Regexp.last_match
          prefix = value[0...match.begin(0)].to_s.last(120)
          immediate_negation = directly_negated?(prefix)
          coordinated_negation = coordinated_negation?(prefix, related_patterns)
          !immediate_negation && !coordinated_negation
        end
      end

      def directly_negated?(prefix)
        return true if prefix.match?(/#{NEGATION_PATTERN}\s*\z/)

        prefix.match?(
          /#{NEGATION_PATTERN}\b\s+(?:tell|instruct|urge|advise|direct|recommend|encourage|ask|require)\b(?:[^.!?;\n]{0,60}\bto)?\s*\z/i
        )
      end

      def coordinated_negation?(prefix, related_patterns)
        negation = prefix.to_enum(:scan, NEGATION_PATTERN).map { Regexp.last_match }.last
        return false unless negation

        suffix = prefix[negation.end(0)..]
        match = suffix.match(/\A(?<prior_clause>.{1,80})\b(?:and|or)\s*\z/i)
        return false unless match

        related_patterns.any? { |pattern| match[:prior_clause].match?(pattern) }
      end
    end
  end
end
