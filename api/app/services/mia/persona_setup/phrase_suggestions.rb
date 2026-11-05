# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Validate model proposals against coach-attributed source words. Never add
    # operations: a quote in a message is not permission to adopt it as a phrase.
    class PhraseSuggestions
      def initialize(message:, coach_name: nil)
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
          next operation if value["text"] == exact && TextEvidence.supports?(operation["evidence_quote"].to_s, value["meaning"].to_s)

          operation.merge("evidence_quote" => exact, "value" => value.merge("text" => exact, "meaning" => exact))
        end
      end

      def exact_quote(text)
        return if text.blank?

        @message.each_line do |line|
          speaker, body = line.split(/:\s*/, 2)
          if body && speaker.split.length <= 3 && speaker.match?(/\A[[:alpha:] .'-]{1,60}\z/) && !speaker.match?(/word for word|phrase|saying/i)
            allowed = [ "coach", "me", "#{@coach_name}" ].reject(&:blank?)
            next unless allowed.any? { |name| speaker.strip.casecmp?(name) }
          else
            body = line
          end
          # The source must identify the coach or explicitly request this phrase.
          # A third party's quote, even inside a coach line, is not her voice.
          body.to_enum(:scan, /["“]([^"”\n]{1,100})["”]/).each do
            match = Regexp.last_match
            next unless self.class.key(match[1]) == self.class.key(text)

            suffix = body[match.end(0)..].to_s.split(/[.!?;\n]/).first.to_s
            next if suffix.match?(/\b(?:should never|must not|is off limits|should not|is banned)\b/i)

            prefix = body[0...match.begin(0)].split(/[.!?;]/).last.to_s
            next if negative_introduction?(prefix) || prefix.match?(/\b(?:client|friend|mother|father|husband|wife|participant|maria)\b/i)
            next unless prefix.match?(/\b(?:i|we|she|her|coach)\b.*\b(?:say|says|saying|phrase)\b|\b(?:add|use|keep)\b.*\b(?:phrase|saying|word for word)\b/i) || (body != line && prefix.strip.empty?)

            return match[1]
          end
          # Exact unquoted authoring commands remain supported.
          return text if body.include?(text) && body.match?(/\b(?:use|add|keep)\b.*\b(?:exact phrase|phrase)\b/i) && !negative_introduction?(body.split(text, 2).first)
        end
        nil
      end

      def self.key(text)
        text.unicode_normalize(:nfkc).downcase.squish.sub(/[.!?]+\z/, "")
      end

      private

      def negative_introduction?(text)
        text.tr("‘’ʼ", "'").match?(/\b(?:not|never|no|(?:do|does|did|ca|wo|would|should|could|is|are|was|were|has|have|had|must)n'?t|stop|avoid|refus\w*|instead|rather|without|delete|take out|ban|remove|drop|hate|get rid|off limits)\b/i)
      end
    end
  end
end
