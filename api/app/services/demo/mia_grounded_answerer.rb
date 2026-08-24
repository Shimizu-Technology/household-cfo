# frozen_string_literal: true

module Demo
  class MiaGroundedAnswerer
    READINESS_PATTERN = /\b(?:readiness|runway(?: gap)?|green gap)\b|\b(?:why|how)\b.{0,40}\b(?:yellow|green|red)\b/i
    SAFE_TO_SPEND_FORMULA_PATTERN = /\bhow\b.{0,80}\b(?:calculate|calculated|derive|derived)\b.{0,80}\bsafe-to-spend\b|\bsafe-to-spend\b.{0,80}\b(?:formula|calculated|derived)\b|\bformula\b.{0,80}\bsafe-to-spend\b/i
    COMPOUND_PURCHASE_DEBT_PATTERN = /(?=.*\b(?:buy|purchase|spend|trip|vacation|book|order)\b)(?=.*(?:\b(?:extra|additional)\b.{0,40}\b(?:debt|credit card|loan)\b|\b(?:debt|credit card|loan)\b.{0,40}\b(?:extra|additional)\b))/i
    PURCHASE_TERM_PATTERN = /(?<!safe-to-)\b(?:buy|purchase|spend|trip|vacation|book|order)\b/i
    DEBT_TERM_PATTERN = /\b(?:debt|credit card|loan)\b/i
    PURCHASE_IMPACT_PATTERN = /\b(?:buy|purchase|spend)\b.*\b(?:runway|safe-to-spend)\b|\b(?:runway|safe-to-spend)\b.*\b(?:buy|purchase|spend)\b/i
    FORWARD_SPENDING_PATTERN = /\bhow much\b.*\b(?:can|could|should|may)\b.*\bspend\b/i
    EXTRA_MONEY_PATTERN = /\b(?:what|how|where)\s+should\s+(?:i|we)\b.*\b(?:do with|use|put|split|allocate|save|pay)\b.*\b(?:bonus|windfall|refund|extra money)\b/i
    APPROVED_SPENDING_LOOKUP_PATTERN = /\bhow much\b.*\b(?:did\b.*\bspend|(?:have|has)\b.*\bspent|spent)\b.*\b(?:at|from)\b|\b(?:what|how much|which|name)\b.{0,120}\b(?:did\b.{0,30}\bspend|spent|transactions?|purchases?)\b/i
    MERCHANT_PATTERN = /\b(?:at|from)\s+([A-Za-z0-9&'’.-]+(?:\s+[A-Za-z0-9&'’.-]+){0,3}?)(?=\s+(?:last|this|in|during|which)\b|[?.!,]|\z)/i
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/

    def initialize(message, facts: Demo::HouseholdData.financial_facts)
      @message = message.to_s.squish
      @facts = facts.deep_symbolize_keys
    end

    def call
      forward_spending = message.match?(FORWARD_SPENDING_PATTERN)
      spending_lookup = message.match?(APPROVED_SPENDING_LOOKUP_PATTERN)
      return compound_spending_answer if forward_spending && spending_lookup
      return forward_spending_answer if forward_spending
      return approved_spending_lookup_answer if spending_lookup
      return safe_to_spend_formula_answer if message.match?(SAFE_TO_SPEND_FORMULA_PATTERN)
      return compound_purchase_debt_answer if compound_purchase_debt_question?
      return purchase_impact_answer if message.match?(PURCHASE_IMPACT_PATTERN)
      return extra_money_answer if message.match?(EXTRA_MONEY_PATTERN)
      return readiness_answer if message.match?(READINESS_PATTERN)

      nil
    end

    private

    attr_reader :message, :facts

    def readiness_answer
      "Your approved readiness is Yellow. The monthly basis is #{money(facts.fetch(:monthly_income))} income, a #{money(facts.fetch(:category_plan))} category plan, and #{money(facts.fetch(:debt_minimums))} in separate debt minimums, for #{money(facts.fetch(:total_monthly_outflow))} total money out and a #{money(facts.fetch(:baseline_surplus))} baseline surplus. #{money(facts.fetch(:protected_liquid))} protected liquid divided by total money out gives #{facts.fetch(:runway_months)} months of runway; the six-month Green target is #{money(facts.fetch(:green_runway_target))}, so the exact Green gap is #{money(facts.fetch(:green_runway_gap))}. Next CFO move: keep debt minimums outside the category-plan subtotal and direct approved surplus toward that Green gap."
    end

    def safe_to_spend_formula_answer
      rate = (HouseholdFinance::ReadinessCalculator::SAFE_TO_SPEND_RATE * 100).round
      surplus = facts.fetch(:baseline_surplus).to_f
      safe = facts.fetch(:safe_to_spend).to_f
      basis = "#{money(facts.fetch(:category_plan))} category plan + #{money(facts.fetch(:debt_minimums))} debt minimums = #{money(facts.fetch(:total_monthly_outflow))} total outflow; #{money(facts.fetch(:monthly_income))} income − #{money(facts.fetch(:total_monthly_outflow))} = #{money(surplus)} baseline surplus."
      if surplus <= 0
        return "Your monthly safe-to-spend guardrail is $0. #{basis} The #{rate}% rule applies only to a positive baseline surplus in Yellow or Green, so a zero or negative surplus does not create discretionary room. It is not a purchase amount or account balance. Next CFO move: restore a positive approved baseline and build runway before approving wants."
      end
      if facts.fetch(:readiness_tone) == "red"
        return "Your monthly safe-to-spend guardrail is $0. #{basis} Although the baseline surplus is positive, Red readiness holds safe-to-spend at $0 until protected runway reaches Yellow; the #{rate}% rule is not active yet. It is not a purchase amount or account balance. Next CFO move: direct the available surplus toward essential bills, expected expenses, and protected runway."
      end

      "Your #{money(safe)} monthly safe-to-spend guardrail is #{rate}% of your #{money(surplus)} positive baseline surplus: #{basis} #{money(surplus)} × #{rate}% = #{money(safe)}. It is a monthly discretionary guardrail, not a purchase amount, account balance, or promise that a specific purchase is funded. The guardrail is available only in Yellow or Green with a positive surplus; Red returns $0. Next CFO move: compare a proposed want with its active category and confirmed spending before approving it."
    end

    def compound_purchase_debt_answer
      purchase_entry, debt_entry = compound_amount_entries
      purchase = purchase_entry.fetch(:value)
      debt_payment = debt_entry.fetch(:value)
      combined = purchase + debt_payment
      safe = facts.fetch(:safe_to_spend).to_f
      surplus = facts.fetch(:baseline_surplus).to_f
      "The proposed purchase is #{money(purchase)}, and the extra debt payment is #{money(debt_payment)}; together they total #{money(combined)}. The purchase alone is #{money([ purchase - safe, 0 ].max)} above the #{money(safe)} safe-to-spend guardrail. The combined plan is #{money([ combined - surplus, 0 ].max)} above the #{money(surplus)} baseline surplus; an extra debt payment is an allocation of surplus, not a second safe-to-spend allowance. Nothing is approved, and this does not prove an account can fund either move. Next CFO move: keep the debt minimum protected, then lower or defer the purchase and name the funding account before considering any extra principal payment."
    end

    def compound_purchase_debt_question?
      return false unless message.match?(COMPOUND_PURCHASE_DEBT_PATTERN)

      compound_amount_entries&.all?
    end

    def amount_entries
      @amount_entries ||= message.to_enum(:scan, AMOUNT_PATTERN).filter_map do
        match = Regexp.last_match
        value = match[1].delete(",").to_f
        { value: value, index: match.begin(0) } if value.positive?
      end
    end

    def compound_amount_entries
      compound_amount_pool.permutation(2).min_by do |purchase_entry, debt_entry|
        purchase_term = nearest_term_index(purchase_entry, PURCHASE_TERM_PATTERN)
        debt_term = nearest_term_index(debt_entry, DEBT_TERM_PATTERN)
        [
          (purchase_entry.fetch(:index) - purchase_term).abs + (debt_entry.fetch(:index) - debt_term).abs,
          (purchase_term - debt_term).abs,
          -purchase_term
        ]
      end
    end

    def compound_amount_pool
      return amount_entries unless amount_entries.length > 2 && message.match?(/\bsafe-to-spend\b/i)

      guardrail_term = message.match(/\bsafe-to-spend\b/i)
      guardrail_entry = amount_entries.min_by { |entry| (entry.fetch(:index) - guardrail_term.begin(0)).abs }
      amount_entries.reject { |entry| entry.equal?(guardrail_entry) }
    end

    def nearest_term_index(entry, term_pattern)
      message.to_enum(:scan, term_pattern).map { Regexp.last_match.begin(0) }.min_by { |index| (entry.fetch(:index) - index).abs }
    end

    def purchase_impact_answer
      amount = message[AMOUNT_PATTERN, 1]&.delete(",")&.to_f
      purchase_label = amount&.positive? ? "The #{money(amount)} purchase" : "The purchase"
      "I cannot calculate the exact runway impact yet because the approved data does not say which account would pay for it or whether protected liquid would decrease. #{purchase_label} is still a pre-spend decision, and safe-to-spend is a monthly guardrail of #{money(facts.fetch(:safe_to_spend))}, not an account balance I can subtract the purchase from. Nothing is approved and no household number changed. Next CFO move: name the funding account and the budget category that would cover it, then I can model the effect without guessing."
    end

    def extra_money_answer
      amount = message[AMOUNT_PATTERN, 1]&.delete(",")&.to_f
      amount_label = amount&.positive? ? "The #{money(amount)} bonus" : "The bonus"
      "#{amount_label} is one-time money, so I would not add it to the #{money(facts.fetch(:monthly_income))} recurring monthly income or use it to inflate readiness. Your approved baseline surplus is #{money(facts.fetch(:baseline_surplus))}, safe-to-spend is #{money(facts.fetch(:safe_to_spend))}, and the six-month runway gap is #{money(facts.fetch(:green_runway_gap))}. Protect any due expected expense or debt minimum first, then direct the remainder toward that runway gap. Next CFO move: verify the bonus net amount and deposit date before assigning it in the annual plan."
    end

    def forward_spending_answer
      "Your approved monthly safe-to-spend guardrail is #{money(facts.fetch(:safe_to_spend))}, but that is not automatic approval for a specific merchant or purchase. The preview has no confirmed transaction ledger, so I cannot verify how much of that guardrail is still available after real spending. Next CFO move: check the purchase against its budget category and confirmed activity before deciding."
    end

    def compound_spending_answer
      "Your approved monthly safe-to-spend guardrail is #{money(facts.fetch(:safe_to_spend))}, but that is not automatic approval for the proposed purchase. The preview has no approved transaction ledger, so I cannot confirm the historical merchant total or how much of the guardrail remains after real spending. Missing records are not proof of $0 spending. Next CFO move: check confirmed activity and the purchase category before deciding."
    end

    def approved_spending_lookup_answer
      merchant = merchant_name
      "The preview has no approved transaction ledger, so I cannot name the merchants or calculate the requested historical total. I also cannot state that you spent $0 at #{merchant} or support another total as a fact. No approved #{merchant} transactions are available here, but missing records are not proof of zero spending. Next CFO move: use a real workspace with confirmed transactions or import the statement for that period, then ask again."
    end

    def merchant_name
      message[MERCHANT_PATTERN, 1].presence || "that merchant"
    end

    def money(value)
      ActiveSupport::NumberHelper.number_to_currency(value, precision: value.to_f % 1 == 0 ? 0 : 2)
    end
  end
end
