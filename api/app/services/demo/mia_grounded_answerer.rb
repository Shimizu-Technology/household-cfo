# frozen_string_literal: true

module Demo
  class MiaGroundedAnswerer
    READINESS_PATTERN = /\b(?:readiness|runway(?: gap)?|green gap)\b|\b(?:why|how)\b.{0,40}\b(?:yellow|green|red)\b/i
    PURCHASE_IMPACT_PATTERN = /\b(?:buy|purchase|spend)\b.*\b(?:runway|safe-to-spend)\b|\b(?:runway|safe-to-spend)\b.*\b(?:buy|purchase|spend)\b/i
    APPROVED_SPENDING_LOOKUP_PATTERN = /\bhow much\b.*\bspen[dt]\b.*\b(?:at|from)\b/i
    MERCHANT_PATTERN = /\b(?:at|from)\s+([A-Za-z0-9&'’.-]+(?:\s+[A-Za-z0-9&'’.-]+){0,3}?)(?=\s+(?:last|this|in|during|and|which)\b|[?.!,]|\z)/i
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/

    def initialize(message, facts: Demo::HouseholdData.financial_facts)
      @message = message.to_s.squish
      @facts = facts.deep_symbolize_keys
    end

    def call
      return approved_spending_lookup_answer if message.match?(APPROVED_SPENDING_LOOKUP_PATTERN)
      return purchase_impact_answer if message.match?(PURCHASE_IMPACT_PATTERN)
      return readiness_answer if message.match?(READINESS_PATTERN)

      nil
    end

    private

    attr_reader :message, :facts

    def readiness_answer
      "Your approved readiness is Yellow. The monthly basis is #{money(facts.fetch(:monthly_income))} income, a #{money(facts.fetch(:category_plan))} category plan, and #{money(facts.fetch(:debt_minimums))} in separate debt minimums, for #{money(facts.fetch(:total_monthly_outflow))} total money out and a #{money(facts.fetch(:baseline_surplus))} baseline surplus. #{money(facts.fetch(:protected_liquid))} protected liquid divided by total money out gives #{facts.fetch(:runway_months)} months of runway; the six-month Green target is #{money(facts.fetch(:green_runway_target))}, so the exact Green gap is #{money(facts.fetch(:green_runway_gap))}. Next CFO move: keep debt minimums outside the category-plan subtotal and direct approved surplus toward that Green gap."
    end

    def purchase_impact_answer
      amount = message[AMOUNT_PATTERN, 1]&.delete(",")&.to_f
      purchase_label = amount&.positive? ? "The #{money(amount)} purchase" : "The purchase"
      "I cannot calculate the exact runway impact yet because the approved data does not say which account would pay for it or whether protected liquid would decrease. #{purchase_label} is still a pre-spend decision, and safe-to-spend is a monthly guardrail of #{money(facts.fetch(:safe_to_spend))}, not an account balance I can subtract the purchase from. Nothing is approved and no household number changed. Next CFO move: name the funding account and the budget category that would cover it, then I can model the effect without guessing."
    end

    def approved_spending_lookup_answer
      merchant = message[MERCHANT_PATTERN, 1].presence || "that merchant"
      "The preview has no approved transaction ledger, so I cannot state that you spent $0 at #{merchant} or support another total as a fact. No approved #{merchant} transactions are available here, but missing records are not proof of zero spending. Next CFO move: use a real workspace with confirmed transactions or import the statement for that period, then ask again."
    end

    def money(value)
      ActiveSupport::NumberHelper.number_to_currency(value, precision: value.to_f % 1 == 0 ? 0 : 2)
    end
  end
end
