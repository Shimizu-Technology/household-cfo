# frozen_string_literal: true

module HouseholdFinance
  class ReadinessCalculator
    SAFE_TO_SPEND_RATE = 0.4

    def initialize(monthly_income_cents:, category_outflow_cents:, debt_minimums_cents:, protected_liquid_cents:, target_runway_months:)
      @monthly_income_cents = monthly_income_cents.to_i
      @category_outflow_cents = category_outflow_cents.to_i
      @debt_minimums_cents = debt_minimums_cents.to_i
      @protected_liquid_cents = protected_liquid_cents.to_i
      @target_runway_months = target_runway_months.to_f
    end

    def call
      {
        total_outflow_cents: total_outflow_cents,
        baseline_surplus_cents: baseline_surplus_cents,
        runway_months: runway_months,
        target_runway_months: target_runway_months,
        readiness_tone: readiness_tone,
        readiness_label: readiness_label,
        safe_to_spend_cents: safe_to_spend_cents,
        yellow_runway_target_cents: yellow_runway_target_cents,
        yellow_runway_gap_cents: runway_gap_cents(yellow_runway_target_cents),
        green_runway_target_cents: green_runway_target_cents,
        green_runway_gap_cents: runway_gap_cents(green_runway_target_cents)
      }
    end

    private

    attr_reader :monthly_income_cents, :category_outflow_cents, :debt_minimums_cents, :protected_liquid_cents, :target_runway_months

    def total_outflow_cents
      category_outflow_cents + debt_minimums_cents
    end

    def baseline_surplus_cents
      monthly_income_cents - total_outflow_cents
    end

    def runway_months
      return 0.0 unless total_outflow_cents.positive?

      (protected_liquid_cents / total_outflow_cents.to_f).round(1)
    end

    def readiness_tone
      return "red" unless total_outflow_cents.positive?
      return "green" if protected_liquid_cents >= green_runway_target_cents && baseline_surplus_cents.positive?
      return "yellow" if protected_liquid_cents >= yellow_runway_target_cents && baseline_surplus_cents >= 0

      "red"
    end

    def readiness_label
      case readiness_tone
      when "green" then "Green — steady, keep building"
      when "yellow" then "Yellow — close, but protect runway"
      else "Red — pause and stabilize basics"
      end
    end

    def safe_to_spend_cents
      return 0 unless baseline_surplus_cents.positive? && readiness_tone != "red"

      (baseline_surplus_cents * SAFE_TO_SPEND_RATE).round
    end

    def yellow_runway_months
      target_runway_months / 2.0
    end

    def yellow_runway_target_cents
      (total_outflow_cents * yellow_runway_months).round
    end

    def green_runway_target_cents
      (total_outflow_cents * target_runway_months).round
    end

    def runway_gap_cents(target_cents)
      [ target_cents - protected_liquid_cents, 0 ].max
    end
  end
end
