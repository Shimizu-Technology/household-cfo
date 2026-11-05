module SpendingPatterns
  # The provider gets verified observations, never permission to estimate facts.
  module Narration
    FIGURE = /\$?\d+(?:,\d{3})*(?:\.\d+)?/.freeze

    private

    def narrator_contract
      shape = persona.respond_to?(:response_shape) ? ::Mia::ResponseShapeRewriter.instruction(persona) : "Use 3-5 short sentences."
      "#{super} For this spending-patterns answer, #{shape} Aim for about 350 characters, in the assigned persona's warm, plain coaching voice. Lead with the biggest flexible spending stops and their recorded window. These merchant totals include only flexible categories; never call them the biggest overall stores or totals. Use participant category names when mentioning a category, never rename them flexible spends. Describe the small-purchase cluster plainly; for Friday through Sunday you can call it a little end-of-week waterfall. Do not speculate about the reason, and do not announce that you are not speculating. End with a comfortable choice between the supplied merchants. Give only the first choice's estimated monthly impact, using the factual sentence Spending half as much at MERCHANT could free about AMOUNT a month, with the supplied merchant and amount. Include coverage in one short clause only if months are missing: use “I only see purchases for Oct: Merchant ($amount) …” for one month, or “I only see purchases for Aug and Oct: Merchant ($amount) …” for several. Join that independent coverage clause with a colon or a separate sentence, never a comma splice; do not recite disclosures. Do not mention subscriptions, other merchants, goals, screens or facts outside this packet. Keep each merchant total in the form Merchant ($amount). Copy each figure exactly from the verified reference; do not round, calculate, spell out new numbers or pair amounts with different merchants. Use could free for the monthly estimate; do not recite estimate-not-savings disclaimers or guardrails. This is a read-only observation, so do not add a review-before-writing disclaimer."
    end

    def narration_rejection_reason(content)
      super || patterns_rejection(content)
    end

    def patterns_rejection(content)
      return :unqualified_flexible_pattern if content.match?(/\b(?:biggest|largest|top)\s+(?:overall\s+)?(?:spending stops?|merchants?|stores?)\b/i)
      sentences = content.to_s.split(::Mia::ResponseShapePolicy::SENTENCE_BOUNDARY)
      return :patterns_response_length unless persona.respond_to?(:response_shape) || sentences.length.between?(3, 5)
      return :spelled_pattern_figure if content.match?(/\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\s+(?:dollars?|purchases?|buys|percent|months?|days?|payments?|charges?|transactions?)\b/i)
      allowed = fallback_response.scan(FIGURE).tally
      return :invented_pattern_figure if content.scan(FIGURE).tally.any? { |figure, count| count > allowed.fetch(figure, 0) }
      return :pattern_coverage_comma_splice if content.match?(/I only see purchases for [^:;.!?]+,\s+[^:;.!?]*\(\$/i)
      return :unrequested_subscription if content.match?(/\bsubscriptions?\b/i)
      facts = answer_packet.fetch(:verified_facts)
      months = Array(facts[:months_with_purchases])
      if months.any?
        named_months = content.scan(/\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b/).map { |month| month.first(3) }
        return :incorrect_pattern_window unless (named_months - months).empty? && [ months.first, months.last ].all? { |month| named_months.include?(month) }
        return :missing_pattern_coverage if facts[:missing_months] && !content.match?(/\bonly\b/i)
      end
      if (cluster = facts[:cluster])
        return :missing_pattern_cluster unless sentences.any? do |sentence|
          sentence.match?(/(?<![$\d])#{cluster[:purchase_count]}\s+(?:small\s+)?(?:buys|purchases)\b/i) && sentence.include?(coaching_money(cluster[:total_cents])) && sentence.include?(cluster[:label])
        end
      end
      if (choice = facts[:choices]&.first)
        merchant = Regexp.escape(choice[:merchant])
        amount = Regexp.escape(coaching_money(choice[:monthly_impact_cents]))
        # Bind the halving action and its amount to the same display name.
        # Merely mentioning Ross elsewhere in a sentence about Kmart is unsafe.
        action = "(?:(?i:Spending half as much at |Halving |Halving spending at )#{merchant}|(?i:Cutting spending at )#{merchant}(?i: in half))"
        estimate = /\A#{action}(?i: could free about )#{amount}(?i: a month)(?:, based on the months recorded)?[.!]\z/
        return :incorrect_pattern_estimate unless sentences.any? { |sentence| sentence.match?(estimate) }
      end
      # Each named spend must retain its own total, not another merchant's figure.
      facts.fetch(:merchants).each do |row|
        amount = coaching_money(row[:total_cents])
        return :missing_pattern_merchant unless content.include?(row[:label])
        return :incorrect_pattern_total unless content.match?(/#{Regexp.escape(row[:label])}\s*\(#{Regexp.escape(amount)}\)/)
      end
      return :missing_comfortable_choice unless content.match?(/\b(?:comfortable|feel better)\b/i) && content.include?("?")
      nil
    end

    def coaching_money(cents)
      whole, fraction = cents.divmod(100)
      "$#{whole}#{fraction.zero? ? '' : ".#{fraction.to_s.rjust(2, '0')}"}"
    end
  end
end
