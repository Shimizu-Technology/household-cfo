module SavingsChallenge
  class Narrator < HouseholdFinance::MiaNarrator
    # The rules of the participant's own challenge (the defaults before she joins).
    def initialize(rules: Rules.default, **options)
      @rules = rules
      super(**options)
    end

    private

    def suggested_dollars = @rules.suggested_goal_cents / 100

    def narrator_contract
      counted = @rules.counts_debt? ? "total new money reserved plus extra debt payments beyond the minimum" : "total new money reserved"
      "#{super} This is the #{@rules.label} savings challenge. The recommended $#{ActiveSupport::NumberHelper.number_to_delimited(suggested_dollars)} is #{counted} over the whole personal window, never a monthly obligation. Check-ins are on #{@rules.checkpoint_text}. Use only the approved facts and coverage in the verified reference. Statements, credit cards, bank links and a full budget are optional. Unknown progress is not zero. Feelings are optional and private. Drafts need participant approval. Lower spending, refunds, #{@rules.counts_debt? ? 'minimum payments' : 'debt payments'} and old or borrowed money do not automatically create savings. Never tell someone to skip essentials or required payments; offer a smaller comfortable target or postponement. Do not invent a complete baseline, successful upload reconciliation, financial write or sharing grant."
    end

    def narration_rejection_reason(content, guard_covered: false)
      super || (challenge_boundary_violation?(content) ? :savings_challenge_boundary : nil)
    end

    def challenge_boundary_violation?(content)
      amount = "(?:500|#{suggested_dollars}|#{ActiveSupport::NumberHelper.number_to_delimited(suggested_dollars)})"
      content.match?(/\$\s*#{amount}\b.{0,30}\b(?:monthly|per month|each month)\b|\b(?:monthly|per month|each month)\b.{0,30}\$\s*#{amount}\b/i) ||
        content.match?(/\b(?:you must|you need to|you are required to|you have to)\b.{0,45}\b(?:full budget|credit card|bank connection)\b/i) ||
        content.match?(/(?:\A|[.!?;]\s*)(?:you (?:must|should|need to) )?(?:skip|stop paying|cut out)\b.{0,30}\b(?:food|meals|rent|housing|medication|medicine|required payments|minimum payments)\b/i) ||
        content.match?(/\b(?:you are|you.re|you have been)\s+(?:lazy|irresponsible|a failure)\b/i) ||
        content.match?(/\b(?:i|we|mia)\s+(?:have\s+|just\s+|already\s+)?(?:saved|reserved|transferred|moved)\b.{0,50}\b(?:money|funds|\$)/i)
    end
  end
end
