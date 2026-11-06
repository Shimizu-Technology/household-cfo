# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Conservative word alignment for free-form suggestions. Unlike the finite
    # voice presets, new prose must keep its factual words, numbers and polarity.
    # Unsupported paraphrases are left out, never silently treated as coach words.
    class TextEvidence
      FILLER = %w[a an the i me my we our you your they their them it its this that these those to of with as is are be being been am was were do does did and then someone people participant participants client clients coach coaching she he her his use using used give say said start starts make followed by ever].freeze
      SYNONYMS = {
        "asks" => "ask", "asking" => "ask", "gives" => "give",
        "celebrates" => "celebrate", "celebrating" => "celebrate", "celebrated" => "celebrate",
        "feeling" => "feel", "feelings" => "feel", "feels" => "feel", "felt" => "feel",
        "shaming" => "shame", "shamed" => "shame", "shames" => "shame",
        "protecting" => "protect", "protects" => "protect",
        "suggestion" => "suggest", "suggestions" => "suggest", "suggesting" => "suggest", "suggests" => "suggest",
        "spending" => "spend", "waiting" => "wait", "waits" => "wait", "days" => "day",
        "payments" => "payment", "utilities" => "utility", "basics" => "basic",
        "deciding" => "decide", "decisions" => "decide", "choice" => "decide", "choices" => "decide",
        "helping" => "help", "helps" => "help", "steps" => "step",
        "telling" => "tell", "tells" => "tell", "overspending" => "overspend",
        "expenses" => "cost", "costs" => "cost", "prioritize" => "protect",
        "pause" => "wait", "pausing" => "wait", "one" => "1", "first" => "1",
        "two" => "2", "three" => "3", "four" => "4", "five" => "5",
        "six" => "6", "seven" => "7", "eight" => "8", "nine" => "9", "ten" => "10",
        "without" => "not", "never" => "not", "no" => "not", "don't" => "not",
        "can't" => "not", "cannot" => "not", "won't" => "not", "wouldn't" => "not",
        "doesn't" => "not", "didn't" => "not", "shouldn't" => "not", "couldn't" => "not",
        "stop" => "not", "stopped" => "not", "avoid" => "not", "avoids" => "not", "avoided" => "not", "avoiding" => "not", "stopping" => "not", "stops" => "not", "refusing" => "not", "refuse" => "not", "rarely" => "not", "seldom" => "not", "hardly" => "not", "scarcely" => "not", "refuses" => "not", "refused" => "not", "nobody" => "not", "none" => "not", "nothing" => "not", "doesnt" => "not", "didnt" => "not", "wouldnt" => "not", "shouldnt" => "not", "isnt" => "not", "hasn't" => "not", "hasnt" => "not", "haven't" => "not", "hadn't" => "not", "dont" => "not", "cant" => "not", "wont" => "not",
        "aren't" => "not", "isn't" => "not", "wasn't" => "not", "weren't" => "not", "mustn't" => "not"
      }.freeze

      def self.supports?(quote, value)
        return true if value.blank?

        claims = clauses(value)
        sources = clauses(quote)
        claims.all? do |claim|
          words = tokens(claim)
          words.any? && sources.any? do |source|
            evidence = tokens(source)
            # A negative/limiting source clause cannot authorize a positive
            # fragment by dropping the cue and its intervening words.
            next false if evidence.any? { |word| word.start_with?("not:") } && words.none? { |word| word.start_with?("not:") }
            restricted = evidence.any? { |word| %w[only when if unless until before after].include?(word) }
            # Quoted example phrases are optional in a paraphrase of a condition;
            # the condition and every other factual word must remain intact.
            protected_words = tokens(source.gsub(/"[^"\n]*"/, ""))
            negatives = evidence.select { |word| word.start_with?("not:") }
            nested = negatives.length > 1 && !evidence.include?("or")
            ordered_subset?(words, evidence) && (!restricted || ordered_subset?(protected_words, words)) &&
              (!nested || (negatives - words).empty?)
          end
        end
      end

      def self.reconcile_prohibitions!(state)
        coaching = state.dig("draft_config", "coaching")
        return unless coaching.is_a?(Hash) && coaching["do"].is_a?(Array) && coaching["do_not"].is_a?(Array)
        return unless (coaching["do"] + coaching["do_not"]).all? { |item| item.is_a?(String) }

        coaching["do"] = coaching["do"].reject do |item|
          coaching["do_not"].any? { |ban| supports?(ban.gsub(/\b(?:do not|don['’ʼ]?t|never|avoid|stop)\b/i, ""), item) }
        end
      end

      def self.ordered_subset?(words, evidence)
        remaining = evidence.dup
        words.chunk_while { |left, right| left == right }.map(&:first).all? do |word|
          index = remaining.index(word)
          index && remaining.slice!(0..index)
        end
      end

      def self.clauses(text)
        # Normalize phone punctuation before contraction matching. Polarity is
        # local: a prohibition in one clause cannot authorize another clause.
        text.unicode_normalize(:nfkc).tr("‘’ʼ", "'").tr("“”", '""').downcase
          .gsub(/\b(i|we|you|they)'(?:m|re)\b/, "\\1 am")
          .gsub(/\bkeep\s+(?=(?:your|the|my|our)\s+(?:voice|tone|style)\b)/, "")
          .gsub(/"[^"\n]*"/) do |phrase|
            # Interior punctuation belongs to the example; a terminal mark
            # before its closing quote still ends the surrounding sentence.
            ending = phrase[/[.!?](?="\z)/]
            phrase.tr(",.;:!?", " ") + ending.to_s
          end
          .gsub(/\binstead of\b|\brefus(?:e|es|ed) to\b|\bused to\b|\bno longer\b/, "not ")
          .split(/(?<!\d)[,.]|[,.](?!\d)|[!?;:]|\b(?:but|and|then)\b/).reject(&:blank?)
      end

      def self.tokens(text)
        words = text.scan(/\d+(?:,\d{3})*(?:\.\d+)?|[[:alpha:]]+(?:'[[:alpha:]]+)?/)
          .reject { |word| FILLER.include?(word) }
          # Present third-person endings share English plural inflections. Keep
          # past/progressive tense intact; polarity is bound below, after this.
          .map { |word| SYNONYMS.fetch(word) { word.delete(",").singularize } }
        # Bind each prohibition to its object; two negatives in a sentence must
        # not cancel or move from "shame" to "spend" during word alignment.
        negative = 0
        previous_negative = 0
        words.filter_map do |word|
          if word == "not" || word.match?(/\A(?:do|does|did|ca|wo|would|should|could|is|are|was|were|has|have|had|must)n'?t\z/)
            negative += 1
            next
          end
          next if negative.positive? && %w[ever should would could must have has had really usually often always to].include?(word)
          if word == "or" && previous_negative.positive?
            negative = previous_negative
            next word
          end
          token = "#{'not:' * negative}#{word}"
          previous_negative = negative
          negative = 0
          token
        end
      end
      private_class_method :clauses, :tokens, :ordered_subset?
    end
  end
end
