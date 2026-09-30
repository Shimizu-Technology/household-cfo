# frozen_string_literal: true

module Mia
  class PersonaSafetyPolicy
    VERSION = 1
    FORBIDDEN_KEY_PATTERN = /(?:\A|[_-])(?:raw[_-])?(?:prompt|system|developer|tool|model|write[_-]authority|write[_-]permissions?|permissions?|guardrails?|safety)(?:[_-]|\z)/i
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
        walk(configuration, "$", errors)
        errors.uniq.first(20)
      end

      private

      def walk(value, path, errors)
        case value
        when Hash
          value.each do |key, child|
            key_name = key.to_s
            errors << "#{path}.#{key_name} is a reserved configuration key" if key_name.match?(FORBIDDEN_KEY_PATTERN)
            walk(child, "#{path}.#{key_name}", errors)
          end
        when Array
          value.each_with_index { |child, index| walk(child, "#{path}[#{index}]", errors) }
        when String
          errors << "#{path} contains safety or prompt-control guidance" if FORBIDDEN_GUIDANCE_PATTERNS.any? { |pattern| value.match?(pattern) }
        end
      end
    end
  end
end
