module SavingsChallenge
  class Narrator < HouseholdFinance::MiaNarrator
    private

    def narrator_contract
      "#{super} This is the 90-day savings challenge. The recommended $500 is total new money reserved over the whole personal window, never a monthly obligation. Use only the approved facts and coverage in the verified reference. Statements, credit cards, bank links and a full budget are optional. Unknown progress is not zero. Feelings are optional and private. Drafts need participant approval. Lower spending, refunds, debt payments and old or borrowed money do not automatically create savings. Never tell someone to skip essentials or required payments; offer a smaller comfortable target or postponement. Do not invent a complete baseline, successful upload reconciliation, financial write or sharing grant."
    end

    def narration_rejection_reason(content)
      super || (challenge_boundary_violation?(content) ? :savings_challenge_boundary : nil)
    end

    def challenge_boundary_violation?(content)
      content.match?(/\$\s*500\b.{0,30}\b(?:monthly|per month|each month)\b|\b(?:monthly|per month|each month)\b.{0,30}\$\s*500\b/i) ||
        content.match?(/\b(?:you must|you need to|you are required to|you have to)\b.{0,45}\b(?:full budget|credit card|bank connection)\b/i) ||
        content.match?(/(?:\A|[.!?;]\s*)(?:you (?:must|should|need to) )?(?:skip|stop paying|cut out)\b.{0,30}\b(?:food|meals|rent|housing|medication|medicine|required payments|minimum payments)\b/i) ||
        content.match?(/\b(?:you are|you.re|you have been)\s+(?:lazy|irresponsible|a failure)\b/i) ||
        content.match?(/\b(?:i|we|mia)\s+(?:have\s+|just\s+|already\s+)?(?:saved|reserved|transferred|moved)\b.{0,50}\b(?:money|funds|\$)/i)
    end
  end
end
