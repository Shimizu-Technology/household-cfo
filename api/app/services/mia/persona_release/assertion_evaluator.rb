# frozen_string_literal: true

module Mia
  module PersonaRelease
    class AssertionEvaluator
      class InvalidAssertion < ArgumentError; end

      TYPES = %w[
        includes excludes includes_any excludes_any max_chars not_fallback
        excludes_configured_phrases no_unapproved_cultural_language
      ].freeze
      MAX_ASSERTIONS = 12
      MAX_VALUES = 20
      MAX_VALUE_LENGTH = 300

      class << self
        def validate!(assertions)
          list = Array(assertions)
          raise InvalidAssertion, "must contain between 1 and #{MAX_ASSERTIONS} typed assertions" unless list.length.between?(1, MAX_ASSERTIONS)

          list.each do |raw|
            assertion = raw.respond_to?(:stringify_keys) ? raw.stringify_keys : {}
            type = assertion["type"].to_s
            raise InvalidAssertion, "contains an unsupported assertion type" unless type.in?(TYPES)

            expected_keys = case type
            when "includes", "excludes" then %w[type value]
            when "includes_any", "excludes_any" then %w[type values]
            when "max_chars" then %w[type value]
            else %w[type]
            end
            raise InvalidAssertion, "contains unexpected assertion fields" unless assertion.keys.sort == expected_keys.sort

            validate_value!(type, assertion)
          end
          true
        end

        def evaluate(assertions, output:, fallback_only:, phrase_artifacts:)
          validate!(assertions)
          Array(assertions).map do |raw|
            assertion = raw.stringify_keys
            passed = passed?(assertion, output.to_s, fallback_only, phrase_artifacts)
            { "type" => assertion.fetch("type"), "passed" => passed }
          end
        end

        private

        def validate_value!(type, assertion)
          case type
          when "includes", "excludes"
            valid_string!(assertion["value"])
          when "includes_any", "excludes_any"
            values = assertion["values"]
            raise InvalidAssertion, "contains an invalid values list" unless values.is_a?(Array) && values.length.between?(1, MAX_VALUES)
            values.each { |value| valid_string!(value) }
          when "max_chars"
            value = Integer(assertion["value"], exception: false)
            raise InvalidAssertion, "contains an invalid maximum length" unless value&.between?(1, 20_000)
          end
        end

        def valid_string!(value)
          raise InvalidAssertion, "contains an invalid string value" unless value.is_a?(String) && value.present? && value.length <= MAX_VALUE_LENGTH
        end

        def passed?(assertion, output, fallback_only, phrase_artifacts)
          normalized = output.downcase
          case assertion.fetch("type")
          when "includes" then normalized.include?(assertion.fetch("value").downcase)
          when "excludes" then !normalized.include?(assertion.fetch("value").downcase)
          when "includes_any" then assertion.fetch("values").any? { |value| normalized.include?(value.downcase) }
          when "excludes_any" then assertion.fetch("values").none? { |value| normalized.include?(value.downcase) }
          when "max_chars" then output.length <= assertion.fetch("value").to_i
          when "not_fallback" then !fallback_only
          when "excludes_configured_phrases"
            Array(phrase_artifacts).none? { |artifact| artifact["text"].present? && normalized.include?(artifact["text"].downcase) }
          when "no_unapproved_cultural_language"
            approved_text = Array(phrase_artifacts).filter_map { |artifact| artifact["text"]&.downcase }
            LanguagePolicy::KNOWN_CULTURAL_PHRASES.none? do |phrase|
              normalized.include?(phrase.downcase) && approved_text.none? { |text| text.include?(phrase.downcase) }
            end
          end
        end
      end
    end
  end
end
