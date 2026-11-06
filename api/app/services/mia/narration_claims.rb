# frozen_string_literal: true

module Mia
  # Semantic approval/write checks remain for callers without an independent guard.
  class NarrationClaims
    def self.rejection_reason(content, confirmed_write: false, guard_covered: false)
      text = content.to_s
      return :participant_system_wording if text.match?(/readiness colou?r|Plaid-derived|liquid account picture|Scenario only/i)
      return :invented_phone if text.match?(/(?<!\d)(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?!\d)|\b(?:call|phone|dial)\s+\+?\d[\d ()-]{2,}/i)
      return :invented_email if text.match?(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)
      return :invented_url if text.match?(%r{https?://|\bwww\.}i)
      return :purchase_verdict if !guard_covered && text.match?(/\b(?:go ahead|i recommend (?:(?:that )?you (?:buy|purchase|book|order|get)|buying|purchasing|booking|ordering|getting|it\b)|plenty of room|no problem|i['’]ve decided|i have decided)\b/i)
      return :purchase_verdict if !guard_covered && text.split(ResponseShapePolicy::SENTENCE_BOUNDARY).any? do |sentence|
        question = sentence.end_with?("?") && sentence.match?(/\A(?:what|which|how|would|could|should|do|does|is|are|can|will|if|when|before)\b/i)
        !question && sentence.match?(/\b(?:you can (?:buy|purchase|book|order)|you (?:should|ought to|must|need to)\s+(?:buy|purchase|book|order)|(?:^|[.!]\s*)(?:please\s+|go\s+)?(?:buy|purchase|book|order)\s+(?:it|the|a|an|this|that))\b/i)
      end
      return :unsupported_balance_claim if text.match?(/\b(?:in (?:the|your) bank|in your account|available to spend)\b/i)
      unless confirmed_write || guard_covered
        text.split(ResponseShapePolicy::SENTENCE_BOUNDARY).each do |sentence|
          next unless sentence.match?(/\b(?:saved|recorded|updated|logged)\b/i)
          new_write = sentence.match?(/\b(?:i|we|mia)(?:['’]ve| have)?\s+(?:just\s+|already\s+)?(?:saved|recorded|updated|logged)\b/i)
          return :false_write_claim if new_write
          # A participant saving cash is not a write receipt from Mia. Keep
          # assistant-subject writes above this exception; app records stay checked below.
          next if sentence.match?(/\byou(?:['’]ve| have)?\s+(?:already\s+)?saved\b/i) && !sentence.match?(/\b(?:records?|purchases?|budget|logged|updated|app|system)\b/i)
          return :false_write_claim if sentence.match?(/\byou(?:['’]ve| have)?\s+(?:already\s+)?saved\s+(?:the |this |that |your |a )?(?:purchase|transaction|budget|record)\b/i)
          passive_write = sentence.match(/\b(?:is|are|was|were|has|have|been|being)\s+(?:[a-z]+\s+){0,3}(?:saved|recorded|updated|logged)\b/i)
          if passive_write
            prefix = sentence[0...passive_write.begin(0)].rstrip
            negated = passive_write[0].match?(/\b(?:not|never)\b/i) || prefix.match?(/\b(?:nothing|no (?:records?|changes?|purchases?))\z/i)
            return :false_write_claim unless negated
          end
          # Adjectives such as "saved cash" and unanswered funding questions
          # do not claim an app action. The semantic guard checks their grounding.
        end
      end
      nil
    end
  end
end
