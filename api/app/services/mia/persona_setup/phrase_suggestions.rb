# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Preserve a supplied phrase without borrowing an unsupported interpretation.
    class PhraseSuggestions
      def initialize(message:)
        @message = message
      end

      def call(operations)
        phrases = quoted_phrases
        operations = operations.map do |operation|
          next operation unless operation.is_a?(Hash) && operation["op"] == "add_phrase" && operation["value"].is_a?(Hash)

          value = operation.fetch("value")
          exact = phrases.find { |phrase| phrase.delete_suffix(".") == value["text"].to_s.delete_suffix(".") }
          next operation unless exact
          next operation if Array(value["allowed_contexts"]).include?("crisis")
          next literal_phrase(exact) if value["text"] != exact
          next operation if TextEvidence.supports?(operation["evidence_quote"].to_s, value["meaning"].to_s)

          literal_phrase(exact)
        end
        phrases.each do |text|
          next if operations.any? { |operation| phrase_text(operation).to_s.delete_suffix(".") == text.delete_suffix(".") }

          operations << literal_phrase(text)
        end
        operations
      end

      private

      def quoted_phrases
        @message.to_enum(:scan, /(?:\b(?:say|says|saying|phrase)\b[^"“\n]{0,80}|word for word:\s*)["“]([^"”\n]{1,100})["”]/i).filter_map do
          match = Regexp.last_match
          prefix = @message[0...match.begin(1)].split(/[.!?;\n]/).last.to_s
          next if prefix.match?(/\b(?:not|never|[a-z]+n['’]t|no longer|remove|drop)\b/i)

          match[1]
        end.uniq
      end

      def phrase_text(operation)
        return unless operation.is_a?(Hash) && operation["path"] == "phrases"

        value = operation["value"]
        value.is_a?(Hash) ? value["text"] : value
      end

      def literal_phrase(text)
        { "op" => "add_phrase", "path" => "phrases", "source_basis" => "coach_quote", "evidence_quote" => text,
          "value" => { "text" => text, "meaning" => text, "allowed_contexts" => [ "general" ],
            "prohibited_contexts" => [ "crisis" ], "frequency" => "rare", "caution" => "" } }
      end
    end
  end
end
