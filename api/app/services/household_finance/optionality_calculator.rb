# frozen_string_literal: true

module HouseholdFinance
  # Read-only savings drawdown: 5% effective annual growth before monthly draws.
  # This is an assumption, never a promised investment return.
  class OptionalityCalculator
    MONTHLY_GROWTH = 1.05**(1.0 / 12) - 1

    def initialize(savings_cents:, monthly_costs_cents:, replacement_income_cents:, monthly_draw_cents: nil)
      @savings, @costs, @income, @draw = savings_cents, monthly_costs_cents, replacement_income_cents, monthly_draw_cents
    end

    def call
      gap = @costs && @income && [ @costs - @income, 0 ].max
      draw = @draw.nil? ? gap : @draw
      if @savings.nil? || draw.nil?
        return { monthly_gap_cents: gap, monthly_draw_cents: draw, months: nil, tone: nil,
                 label: "Add savings, household costs and replacement income" }
      end

      sustainable = draw.zero? || @savings * MONTHLY_GROWTH >= draw
      months = if sustainable
        nil
      elsif !@savings.positive?
        0
      else
        # B(n) = S(1+r)^n - D((1+r)^n-1)/r. Count fully funded months.
        (Math.log(draw / (draw - @savings * MONTHLY_GROWTH)) / Math.log(1 + MONTHLY_GROWTH)).floor
      end
      tone, label = if sustainable || months >= 36
        [ "green", "Comfortable window to build" ]
      elsif months >= 18
        [ "yellow", "Workable — move fast" ]
      else
        [ "red", "Tight — business revenue needed quickly" ]
      end
      { monthly_gap_cents: gap, monthly_draw_cents: draw, months: months, sustainable: sustainable,
        tone: tone, label: label, annual_growth_percent: 5 }
    end
  end
end
