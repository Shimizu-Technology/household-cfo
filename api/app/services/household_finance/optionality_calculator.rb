# frozen_string_literal: true

module HouseholdFinance
  # Read-only savings drawdown: 5% nominal annual growth before monthly draws.
  # This is an assumption, never a promised investment return.
  class OptionalityCalculator
    MONTHLY_GROWTH = 0.05 / 12

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

      balance = @savings.to_f
      months = 0
      while balance.positive? && months < 1200
        balance = [ balance * (1 + MONTHLY_GROWTH) - draw, 0 ].max
        months += 1
      end
      sustainable = months == 1200 || draw.zero?
      months = nil if sustainable
      tone, label = if sustainable || months >= 36
        [ "green", "Comfortable window to build" ]
      elsif months >= 18
        [ "yellow", "Workable — move fast" ]
      else
        [ "red", "Tight — business revenue needed quickly" ]
      end
      { monthly_gap_cents: gap, monthly_draw_cents: draw, months: months, sustainable: sustainable,
        tone: tone, label: label, annual_growth_percent: 5, uncovered_monthly_gap_cents: gap && [ gap - draw, 0 ].max, business_required_annual_cents: gap && [ gap - draw, 0 ].max * 12, sources_cover_need: gap == 0 }
    end
  end
end
