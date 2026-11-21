# frozen_string_literal: true

module HouseholdFinance
  # Mrs. Mel's status colours, read from the program's method settings:
  # a target is Green when this month's surplus reaches it within the green
  # months, Yellow within the yellow months, Red beyond (or never). The monthly
  # base surplus has its own colour. Readiness is the emergency fund target's colour.
  #
  # The colour assumes the whole surplus goes to the target, so safe-to-spend is
  # never more than the household can spend and still keep the colour shown.
  class ReadinessCalculator
    SAFE_TO_SPEND_RATE = 0.4

    def initialize(monthly_income_cents:, category_outflow_cents:, debt_minimums_cents:, protected_liquid_cents:, target_runway_months:,
      status: CohortExperience::MethodSettings::DEFAULTS.fetch("status"))
      @monthly_income_cents = monthly_income_cents.to_i
      @category_outflow_cents = category_outflow_cents.to_i
      @debt_minimums_cents = debt_minimums_cents.to_i
      @protected_liquid_cents = protected_liquid_cents.to_i
      @target_runway_months = target_runway_months.to_f
      @status = status.to_h.stringify_keys
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
        surplus_kept_for_tone_cents: surplus_kept_for_tone_cents,
        emergency_fund_target_cents: emergency_fund_target_cents,
        emergency_fund_gap_cents: emergency_fund_gap_cents,
        months_to_target: months_to_target,
        surplus_tone: surplus_tone,
        surplus_label: surplus_label,
        status_rule: status
      }
    end

    def self.months_to_reach(gap_cents, surplus_cents)
      return 0 unless gap_cents.positive?
      return nil unless surplus_cents.positive?

      (gap_cents.to_f / surplus_cents).ceil
    end

    def self.target_tone(months, status)
      return "red" if months.nil?
      return "green" if months <= status.fetch("target_green_months")
      return "yellow" if months <= status.fetch("target_yellow_months")

      "red"
    end

    private

    attr_reader :monthly_income_cents, :category_outflow_cents, :debt_minimums_cents, :protected_liquid_cents, :target_runway_months, :status

    def total_outflow_cents
      category_outflow_cents + debt_minimums_cents
    end

    def baseline_surplus_cents
      monthly_income_cents - total_outflow_cents
    end

    def runway_months
      return 0.0 unless total_outflow_cents.positive?

      exact = protected_liquid_cents / total_outflow_cents.to_f
      rounded = exact.round(1)
      # Never round up onto a target the household has not met, so "3.0 months"
      # cannot sit beside a target that still needs money.
      crossed_unmet_line = rounded >= target_runway_months && protected_liquid_cents < emergency_fund_target_cents
      crossed_unmet_line ? (exact * 10).floor / 10.0 : rounded
    end

    def emergency_fund_target_cents
      (total_outflow_cents * target_runway_months).round
    end

    def emergency_fund_gap_cents
      [ emergency_fund_target_cents - protected_liquid_cents, 0 ].max
    end

    def months_to_target
      self.class.months_to_reach(emergency_fund_gap_cents, baseline_surplus_cents)
    end

    def readiness_tone
      return "red" unless total_outflow_cents.positive?

      self.class.target_tone(months_to_target, status)
    end

    def readiness_label
      return "Setup incomplete — add planned monthly costs to set the emergency fund target" unless total_outflow_cents.positive?

      case readiness_tone
      when "green"
        emergency_fund_gap_cents.zero? ? "Green — emergency fund target reached" : "Green — emergency fund target within #{months(status.fetch('target_green_months'))}"
      when "yellow" then "Yellow — emergency fund target within #{months(status.fetch('target_yellow_months'))}"
      else
        baseline_surplus_cents.positive? ? "Red — emergency fund target more than #{months(status.fetch('target_yellow_months'))} away" : "Red — bring planned costs within income to build the emergency fund"
      end
    end

    def surplus_tone
      return "green" if baseline_surplus_cents >= status.fetch("surplus_green_cents")
      return "yellow" if baseline_surplus_cents >= status.fetch("surplus_yellow_cents")

      "red"
    end

    def surplus_label
      case surplus_tone
      when "green" then "Green — monthly surplus at or above #{Money.plain(status.fetch('surplus_green_cents'))}"
      when "yellow" then "Yellow — monthly surplus at or above #{Money.plain(status.fetch('surplus_yellow_cents'))}"
      else "Red — monthly surplus below #{Money.plain(status.fetch('surplus_yellow_cents'))}"
      end
    end

    def safe_to_spend_cents
      return 0 unless baseline_surplus_cents.positive? && readiness_tone != "red"

      rate_cents = (baseline_surplus_cents * SAFE_TO_SPEND_RATE).round
      return rate_cents unless emergency_fund_gap_cents.positive?

      [ rate_cents, baseline_surplus_cents - surplus_to_keep_tone_cents ].min.clamp(0, rate_cents)
    end

    # The part of the surplus that must keep going to the target for the colour to hold,
    # when that is what limits safe-to-spend; nil otherwise.
    def surplus_kept_for_tone_cents
      return nil unless baseline_surplus_cents.positive? && readiness_tone != "red" && emergency_fund_gap_cents.positive?

      surplus_to_keep_tone_cents
    end

    # The least whole-cent monthly surplus that still reaches the gap inside the shown
    # colour's months: ceil(gap / s) <= months exactly when s >= ceil(gap / months).
    def surplus_to_keep_tone_cents
      line = status.fetch(readiness_tone == "green" ? "target_green_months" : "target_yellow_months")
      (emergency_fund_gap_cents + line - 1) / line
    end

    def months(count)
      "#{count} #{'month'.pluralize(count)}"
    end
  end
end
