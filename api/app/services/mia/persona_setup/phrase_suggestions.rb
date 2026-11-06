# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Validate model proposals against coach-attributed source words. Never add
    # operations: a quote in a message is not permission to adopt it as a phrase.
    class PhraseSuggestions
      def initialize(message:, coach_name: nil, phrases: nil)
        @message = message
        @coach_name = coach_name
      end

      def call(operations)
        operations.map do |operation|
          next operation unless operation.is_a?(Hash) && operation["op"] == "add_phrase" && operation["value"].is_a?(Hash)

          value = operation.fetch("value")
          exact = exact_quote(value["text"].to_s)
          next operation unless exact
          next operation if Array(value["allowed_contexts"]).include?("crisis")
          operation.merge("value" => value.merge("text" => exact))
        end
      end

      def exact_quote(text)
        return if text.blank?

        @message.each_line do |line|
          body = coach_source(line)
          next unless body
          # The source must identify the coach or explicitly request this phrase.
          # A third party's quote, even inside a coach line, is not her voice.
          body.to_enum(:scan, /["“]([^"”\n]{1,100})["”]/).each do
            match = Regexp.last_match
            next unless self.class.key(match[1]) == self.class.key(text)

            suffix = body[match.end(0)..].to_s
            next if negative_suffix?(suffix)

            prefix = body[0...match.begin(0)].split(/[.!?;]/).last.to_s
            # A negative financial condition ("money they do not have")
            # is not a ban on the following affirmative "I say".
            attribution = prefix.match(/\b(?:i|we|she|the coach)\s+(?:(?:always|often|sometimes|usually)\s+)?(?:say|says|am saying|is saying)\s*[:,-]?\s*\z/i)
            condition = prefix.match?(/\A\s*when\b/i) && attribution
            next if negative_introduction?(condition ? attribution[0] : prefix)
            next unless prefix.match?(/\b(?:(?:i|we|she|the coach)\s+(?:(?:always|often|sometimes|usually)\s+)?(?:say|says|am saying|is saying)|her\s+(?:phrase|saying)\s+is)\s*[:,-]?\s*\z|\A\s*(?:please\s+)?(?:add|use|keep)\b[^"“]*\b(?:phrase|saying|word for word)\b[^"“]*\z/i) || prefix.match?(/\b(?:use|add|keep)\s+(?:my|our|her|the coach['’]s)\s+(?:exact\s+)?(?:phrase|saying)\s*[:,-]?\s*\z/i) || prefix.match?(/\A\s*also\s+say\s*[:,-]?\s*\z/i) || (body != line && prefix.strip.empty?)

            return match[1]
          end
          # Exact unquoted authoring commands remain supported.
          if body.include?(text)
            prefix = body.split(text, 2).first.split(/[.!?;]/).last.to_s
            suffix = body.split(text, 2).last.to_s.split(/[.!?;\n]/).first.to_s
            return text if !negative_suffix?(suffix) && prefix.match?(/\A\s*(?:please\s+)?(?:use|add|keep)\s+(?:the\s+)?(?:exact\s+)?phrase\s*[:,-]?\s*\z/i) && !negative_introduction?(prefix)
          end
        end
        nil
      end

      def self.key(text)
        text.unicode_normalize(:nfkc).tr("‘’ʼ", "'").downcase.squish.sub(/[.!?]+\z/, "")
      end

      private

      def coach_source(line)
        CoachSource.new(coach_name: @coach_name).body(line)
      end

      def negative_suffix?(text)
        text.tr("‘’ʼ", "'").match?(/\b(?:not anymore|no longer|should never|must not|is off limits|should not|is banned|(?:do\s+not|don't|never|avoid|stop)\s+(?:use|using|add|adding|keep|keeping|adopt|adopting|say|saying))\b/i)
      end

      def negative_introduction?(text)
        text.tr("‘’ʼ", "'").match?(/\b(?:not|never|no|(?:do|does|did|ca|wo|would|should|could|is|are|was|were|has|have|had|must)n'?t|stop|avoid|refus\w*|instead|rather|without|delete|take out|ban|remove|drop|hate|get rid|off limits)\b/i)
      end
    end
  end
end
