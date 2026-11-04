# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Conservative word alignment for free-form suggestions. Unlike the finite
    # voice presets, new prose must keep its factual words, numbers and polarity.
    # Unsupported paraphrases are left out, never silently treated as coach words.
    class TextEvidence
      FILLER = %w[a an the i me my we our you your they their them it its this that these those to of with as is are be being been am was were and then when someone people participant participants client clients coach coaching use using used give say said start starts keep make only followed by].freeze
      SYNONYMS = {
        "feeling" => "feel", "feelings" => "feel", "feels" => "feel", "felt" => "feel",
        "shaming" => "shame", "shamed" => "shame", "shames" => "shame",
        "protecting" => "protect", "protects" => "protect",
        "suggestion" => "suggest", "suggestions" => "suggest", "suggesting" => "suggest",
        "waiting" => "wait", "waits" => "wait", "days" => "day",
        "payments" => "payment", "utilities" => "utility", "basics" => "basic",
        "deciding" => "decide", "decisions" => "decide", "choice" => "decide", "choices" => "decide",
        "helping" => "help", "helps" => "help", "steps" => "step",
        "telling" => "tell", "tells" => "tell", "overspending" => "overspend",
        "expenses" => "cost", "costs" => "cost", "prioritize" => "protect",
        "pause" => "wait", "pausing" => "wait", "one" => "1", "first" => "1",
        "without" => "not", "never" => "not", "no" => "not", "don't" => "not"
      }.freeze

      def self.supports?(quote, value)
        return true if value.blank?

        claims = value.split(/[.!?;]|\bbut\b/i).reject(&:blank?)
        sources = quote.split(/[.!?;]|\bbut\b/i)
        claims.all? do |claim|
          words = tokens(claim)
          words.any? && sources.any? do |source|
            evidence = tokens(source)
            (words - evidence).empty? && words.include?("not") == evidence.include?("not")
          end
        end
      end

      def self.tokens(text)
        text.unicode_normalize(:nfkc).downcase.scan(/[[:alnum:]]+(?:'[[:alpha:]]+)?/)
          .reject { |word| FILLER.include?(word) }
          .map { |word| SYNONYMS.fetch(word, word) }.uniq
      end
      private_class_method :tokens
    end
  end
end
