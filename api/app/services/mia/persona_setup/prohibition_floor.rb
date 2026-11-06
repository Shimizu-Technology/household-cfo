# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Only remove an exact duplicated instruction when the coach also bans it.
    # Semantic polarity and paraphrases belong to ProposalGuard.
    module ProhibitionFloor
      def self.reconcile!(state)
        coaching = state.dig("draft_config", "coaching")
        return unless coaching.is_a?(Hash) && coaching["do"].is_a?(Array) && coaching["do_not"].is_a?(Array)

        bans = coaching["do_not"].filter_map do |item|
          next unless item.is_a?(String)

          normalize(item).sub(/\A(?:do not|don't|never|avoid|stop)\s+/, "")
        end
        coaching["do"] = coaching["do"].reject { |item| item.is_a?(String) && bans.include?(normalize(item)) }
      end

      def self.normalize(text)
        text.unicode_normalize(:nfkc).tr("‘’ʼ", "'").downcase.squish.sub(/[.!?]+\z/, "")
      end
    end
  end
end
