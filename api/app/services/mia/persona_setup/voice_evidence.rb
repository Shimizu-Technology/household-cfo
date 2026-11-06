# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Finite presets translate descriptions, but never grant unrelated choices.
    # Each group is required; alternatives within a group are synonyms.
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
        "lighthearted" => [ "lighthearted|humou?r|playful|funny" ],
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
        quote[match.end(0)..].match?(/\A(?:\s*[,.;:!?"'”’]|\s*\z|\s+(?:and|or|tone|voice|style|language|words|wording|manner|approach|energy|answers?|responses?|replies|sentences?|questions?|coaching|accountability|coach|briefly|next step|older cousin|auntie|aunt|friend|cousin|who|with|to|about tradeoffs)\b)/i)
      end

      def self.supports?(quote, value, removal: false)
        groups = PRESETS[value]
        return false unless groups

        groups.all? do |alternatives|
          quote.to_enum(:scan, /\b(?:#{alternatives})\b/i).any? do
            match = Regexp.last_match
            next false unless descriptive_use?(quote, match)

            prefix = quote[0...match.begin(0)].split(/[.!?;]|\bbut\b/i).last.to_s
            # A negation scopes the following list until a sentence or contrast.
            # Negative synonyms ("never shaming") are a single supporting match.
            removal ? removal_requested?(prefix) : !prefix.match?(NEGATION)
          end
        end
      end
    end
  end
end
