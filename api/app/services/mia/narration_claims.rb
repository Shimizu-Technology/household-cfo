# frozen_string_literal: true

module Mia
  # Model prose never supplies a spending verdict, contact number, or write receipt.
  class NarrationClaims
    def self.rejection_reason(content, confirmed_write: false)
      text = content.to_s
      return :participant_system_wording if text.match?(/readiness colou?r|Plaid-derived|liquid account picture|Scenario only/i)
      return :invented_phone if text.match?(/(?<!\d)(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?!\d)|\b(?:call|phone|dial)\s+\+?\d[\d ()-]{2,}/i)
      return :purchase_verdict if text.match?(/\b(?:go ahead|you can buy|i recommend|plenty of room|no problem|i['’]ve decided|i have decided)\b/i)
      return :unsupported_balance_claim if text.match?(/\b(?:in (?:the|your) bank|in your account|available to spend)\b/i)
      unless confirmed_write
        text.split(ResponseShapePolicy::SENTENCE_BOUNDARY).each do |sentence|
          next unless sentence.match?(/\b(?:saved|recorded|updated|logged)\b/i)
          new_write = sentence.match?(/\b(?:i|we|mia)(?:['’]ve| have)?\s+(?:just\s+|already\s+)?(?:saved|recorded|updated|logged)\b/i)
          return :false_write_claim if new_write
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
