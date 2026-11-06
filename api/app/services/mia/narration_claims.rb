# frozen_string_literal: true

module Mia
  # Model prose never supplies a spending approval, contact number, or write receipt.
  class NarrationClaims
    def self.rejection_reason(content, confirmed_write: false)
      text = content.to_s
      return :participant_system_wording if text.match?(/readiness colou?r|Plaid-derived|liquid account picture|Scenario only/i)
      return :invented_phone if text.match?(/(?<!\d)(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?!\d)|\b(?:call|phone|dial)\s+\+?\d[\d ()-]{2,}/i)
      return :purchase_verdict if text.match?(/\b(?:go ahead|you can (?:buy|purchase|book|order)|i recommend (?:(?:that )?you (?:buy|purchase|book|order|get)|buying|purchasing|booking|ordering|getting|it\b)|plenty of room|no problem|i['’]ve decided|i have decided)\b/i)
      return :purchase_verdict if text.split(ResponseShapePolicy::SENTENCE_BOUNDARY).any? { |sentence| !(sentence.end_with?("?") && sentence.match?(/\A(?:what|which|how|would|could|should|do|does|is|are|can|will)\b/i)) && sentence.match?(/\b(?:you (?:should|ought to|must|need to)\s+(?:buy|purchase|book|order)|(?:^|[.!]\s*)(?:please\s+|go\s+)?(?:buy|purchase|book|order)\s+(?:it|the|a|an|this|that))\b/i) }
      return :unsupported_balance_claim if text.match?(/\b(?:in (?:the|your) bank|in your account|available to spend)\b/i)
      unless confirmed_write
        text.split(ResponseShapePolicy::SENTENCE_BOUNDARY).each do |sentence|
          next unless sentence.match?(/\b(?:saved|recorded|updated|logged)\b/i)
          new_write = sentence.match?(/\b(?:i|we|mia)(?:['’]ve| have)?\s+(?:just\s+|already\s+)?(?:saved|recorded|updated|logged)\b/i)
          return :false_write_claim if new_write
          # A participant saving cash is not a write receipt from Mia. Keep
          # assistant-subject writes above this exception; app records stay checked below.
          next if sentence.match?(/\byou(?:['’]ve| have)?\s+(?:already\s+)?saved\b/i) && !sentence.match?(/\b(?:records?|logged|updated|app|system)\b/i)
          passive_write = sentence.match(/\b(?:is|are|was|were|has|have|been|being)\s+(?:[a-z]+\s+){0,3}(?:saved|recorded|updated|logged)\b/i)
          if passive_write
            prefix = sentence[0...passive_write.begin(0)].rstrip
            negated = passive_write[0].match?(/\b(?:not|never)\b/i) || prefix.match?(/\b(?:nothing|no (?:records?|changes?|purchases?))\z/i)
            return :false_write_claim unless negated
          end
          saved_balance_description = sentence.match?(/\bsaved\s+[^.!?]{0,100}\bbalances?\b/i) && !sentence.match?(/\b(?:is|are|was|were|been|being)\s+(?:just\s+)?saved\b/i)
          next if saved_balance_description
          next if sentence.match?(/\b(?:already on record|historical|existing|previously recorded)\b/i)
          next if sentence.match?(/\b(?:not|nothing|never)\b.{0,50}\b(?:saved|recorded|updated|logged)\b|\b(?:until|before)\b.{0,50}\b(?:saved|recorded|updated|logged)\b|\b(?:saved (?:plan|records?|amounts?)|recorded (?:purchases|spending|transactions|amounts))\b/i)

          return :false_write_claim
        end
      end
      nil
    end
  end
end
