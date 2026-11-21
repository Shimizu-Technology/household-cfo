# frozen_string_literal: true

module HouseholdFinance
  # Cents throughout. The proposed purchase reduces this month's surplus only;
  # future income and saved balances remain unchanged. Each target is independent.
  class CfoFilterCalculator
    def initialize(income_cents:, costs_cents:, savings_cents:, debt_cents:, method:, target_runway_months: nil)
      @income, @costs, @savings, @debt, @method = income_cents, costs_cents, savings_cents, debt_cents, method
      @target_runway_months = target_runway_months || method.fetch("emergency_fund_months")
    end

    def call(spend_cents: 0, windfall_cents: 0)
      surplus = @income && @costs && @income - @costs
      gap = @costs && @savings && [ (@costs * @target_runway_months).round - @savings, 0 ].max
      after = surplus && surplus - spend_cents
      {
        base_surplus_cents: surplus, after_spend_surplus_cents: after,
        before: state(gap, surplus), after: state(gap, after),
        targets: [ target("Emergency fund", gap, surplus), target("Debt payoff", @debt, surplus), surplus_target(surplus) ],
        windfall: WindfallSplit.new(amount_cents: windfall_cents, order: @method.fetch("windfall"),
          emergency_fund_gap_cents: gap, consumer_debt_cents: @debt).call
      }
    end

    private

    def state(gap, surplus)
      months = gap && surplus && ReadinessCalculator.months_to_reach(gap, surplus)
      { emergency_months: months, emergency_tone: gap && surplus && ReadinessCalculator.target_tone(months, status),
        surplus_tone: surplus && (surplus >= status.fetch("surplus_green_cents") ? "green" : surplus >= status.fetch("surplus_yellow_cents") ? "yellow" : "red") }
    end

    def status = @method.fetch("status")

    def target(label, gap, surplus)
      months = gap && surplus && ReadinessCalculator.months_to_reach(gap, surplus)
      { label: label, gap_cents: gap, months: months, tone: gap && surplus && ReadinessCalculator.target_tone(months, status),
        yellow: requirement(gap && (gap.to_f / status.fetch("target_yellow_months")).ceil, surplus),
        green: requirement(gap && (gap.to_f / status.fetch("target_green_months")).ceil, surplus) }
    end

    def surplus_target(surplus)
      { label: "Base surplus", gap_cents: nil, months: nil, tone: state(nil, surplus)[:surplus_tone],
        yellow: requirement(status.fetch("surplus_yellow_cents"), surplus), green: requirement(status.fetch("surplus_green_cents"), surplus) }
    end

    def requirement(needed, surplus)
      { surplus_cents: needed, income_cents: needed && @costs && @costs + needed,
        extra_cents: needed && surplus && [ needed - surplus, 0 ].max }
    end
  end
end
