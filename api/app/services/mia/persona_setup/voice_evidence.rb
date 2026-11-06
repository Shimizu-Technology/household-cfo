# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Finite presets are reviewable mappings, not authored prose. This vocabulary
    # detects contradictions and explicit removals; it does not require the
    # coach to describe her voice with words from the menu.
    class VoiceEvidence
      TRAITS = {
        "warm" => [ "warm|friendly|kind" ],
        "direct" => [ "direct|straightforward|straight to the point" ],
        "respectful" => [ "respectful|dignity|without sham(?:e|ing)|never sham(?:e|ing)|non[ -]?shaming" ],
        "calm" => [ "calm|quiet|steady" ],
        "encouraging" => [ "encouraging|encourage|supportive" ],
        "candid" => [ "candid|honest|frank" ],
        "patient" => [ "patient|unhurried|take (?:our|your|their) time" ],
        "concise" => [ "concise|brief|briefly|short|succinct" ],
        "practical" => [ "practical|concrete|actionable" ],
        "reassuring" => [ "reassuring|reassure|comforting" ],
        "lighthearted" => [ "lighthearted|humou?r|playful|funny|jok(?:e|es|ing)" ],
        "formal" => [ "formal|professional" ],
        "clear" => [ "clear|plain|simple" ],
        "unhurried" => [ "unhurried|patient|slow|take (?:our|your|their) time" ]
      }.freeze
      PRESETS = TRAITS.merge(
        "Calm and focused." => [ TRAITS.fetch("calm").first, "focused|focus" ],
        "Calm, clear, and concise." => %w[calm clear concise].map { |key| TRAITS.fetch(key).first },
        "Steady and reassuring." => [ "steady|calm", TRAITS.fetch("reassuring").first ],
        "Warm and encouraging." => %w[warm encouraging].map { |key| TRAITS.fetch(key).first },
        "Direct and energetic." => [ TRAITS.fetch("direct").first, "energetic|energy|lively" ],
        "Quiet and unhurried." => [ "quiet|calm", TRAITS.fetch("unhurried").first ],
        "Name choices and patterns clearly while protecting the participant's dignity." => [ "choices?|patterns?", "dignity|respectful|never shaming|without shame" ],
        "Ask reflective questions before naming a pattern." => [ "reflective|reflect|questions?", "patterns?" ],
        "Be direct about tradeoffs while staying respectful." => [ "direct|tradeoffs?", TRAITS.fetch("respectful").first ],
        "Use gentle accountability and one practical next step." => [ "gentle|never shaming|without shame", "practical|concrete|clear", "next step" ],
        "Keep accountability firm, calm, and specific." => [ "firm", TRAITS.fetch("calm").first, "specific|concrete" ],
        "Use plain language." => [ "plain|simple|everyday|without jargon" ],
        "Keep the next step concrete." => [ "next step", "concrete|practical|clear" ],
        "Use short sentences and concrete questions." => [ "short sentences|brief sentences", "concrete questions|practical questions|specific questions" ],
        "Prefer conversational language." => [ "conversational|casual|like (?:a |an |my |your )?(?:friend|cousin)|older cousin" ],
        "Keep the tone professional and formal." => [ TRAITS.fetch("formal").first ],
        "Use light humor only when the situation is not sensitive." => [ TRAITS.fetch("lighthearted").first ],
        "Be concise and avoid unnecessary jargon." => [ TRAITS.fetch("concise").first, "without jargon|avoid (?:unnecessary )?jargon|plain|simple" ],
        "Explain unfamiliar financial terms briefly." => [ "explain|define", "terms|jargon", TRAITS.fetch("concise").first ]
      ).freeze
      NEGATION = /\b(?:no|not|nothing|never|without|avoid|stop|remove|drop|don't|do not|isn't)\b/i
      REMOVAL = /\b(?:remove|drop|stop|replace|replacing|instead of|no|not|nothing|never|without|avoid|don't|do not)\b/i

      def self.removal_requested?(prefix)
        action = prefix.to_enum(:scan, /\b(?:remove|drop|stop|replace|replacing|instead of|keep|retain|use|add|stay|remain)\b/i).map { Regexp.last_match }.last
        return prefix.match?(REMOVAL) unless action

        negated = prefix[0...action.begin(0)].match?(/\b(?:do not|don't|never|not)\s+(?:please\s+)?\z/i)
        if action[0].match?(/\A(?:keep|retain|use|add|stay|remain)\z/i)
          negated
        else
          !negated
        end
      end

      def self.descriptive_use?(quote, match)
        return true if match[0].match?(/\s/)
        # These are teaching actions/objects, not descriptive adjectives. Their
        # surrounding nouns must not be judged like "direct deposit".
        return true if match[0].match?(/\A(?:explain|define|terms|jargon|reflect|questions?|patterns?|choices?|tradeoffs?)\z/i)

        # A bare descriptor, adjective list, or communication phrase can
        # support voice. Generic noun phrases such as "warm weather" and
        # "direct deposit" cannot borrow that adjective for a voice choice.
        quote[match.end(0)..].match?(/\A(?:\s*[,.;:!?"'”’]|\s*\z|\s+(?:only|when|if|unless|until|about|for|and|or|tone|voice|style|language|words|wording|manner|approach|energy|answers?|responses?|replies|sentences?|questions?|coaching|accountability|coach|briefly|next step|older cousin|auntie|aunt|friend|cousin|who|with|to|about tradeoffs)\b)/i)
      end

      def self.about_voice?(text)
        return true if text.match?(/\b(?:voice|tone|style|sound|speak|talk|coach|coaching|respond|reply|replies|answers|wording|language|humou?r|jokes?)\b/i)
        return true if text.match?(/\b(?:i|we|she)\s*(?:['’]m|['’]re|am|are|is|want|leave|listen|ask|explain)\b/i)
        return true if text.match?(/\b(?:keep|be|stay|remain|use)\s+(?:it|things|the tone|my voice)\b/i)

        TRAITS.values.flatten.any? do |alternatives|
          text.to_enum(:scan, /\b(?:#{alternatives})\b/i).any? { descriptive_use?(text, Regexp.last_match) }
        end
      end

      def self.supports?(quote, value, removal: false)
        groups = PRESETS[value]
        return false unless groups
        return !contradicted?(quote, value) unless removal

        groups.all? do |alternatives|
          quote.to_enum(:scan, /\b(?:#{alternatives})\b/i).any? do
            match = Regexp.last_match
            descriptive_use?(quote, match) && removal_requested?(quote[0...match.begin(0)].split(/[.!?;]|\bbut\b/i).last.to_s)
          end
        end
      end

      def self.contradicted?(quote, value)
        PRESETS.fetch(value).any? do |alternatives|
          mentions = quote.to_enum(:scan, /\b(?:#{alternatives})\b/i).map do
            match = Regexp.last_match
            next unless descriptive_use?(quote, match)

            prefix = quote[0...match.begin(0)].split(/[.!?;]|\bbut\b/i).last.to_s
            suffix = quote[match.end(0)..].split(/[.!?;]|\bbut\b/i).first.to_s
            prefix.match?(NEGATION) || prefix.match?(/\b(?:only|unless|until)\b/i) ||
              suffix.match?(/\A[^,]*\b(?:only|when|if|unless|until)\b/i)
          end
          # An explicit later correction can replace an earlier instruction.
          mentions.compact.last == true
        end
      end
    end
  end
end
