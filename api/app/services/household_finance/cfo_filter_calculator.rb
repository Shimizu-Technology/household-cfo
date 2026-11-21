# frozen_string_literal: true

module HouseholdFinance
  # Request-local comparisons. Rational cents preserve the annual split exactly.
  class CfoFilterCalculator
    def initialize(income_cents:, costs_cents:, savings_cents:, debt_cents:, method:, target_runway_months: nil, debts: nil, wealth_tone: nil)
      @income, @costs, @savings, @debt, @method = income_cents, costs_cents, savings_cents, debt_cents, method
      @debts, @wealth_tone = debts, wealth_tone
      @target_runway_months = target_runway_months || method.fetch("emergency_fund_months")
    end

    def call(spend_cents: 0, windfall_cents: 0, lift_cents: 0)
      surplus = @income && @costs && @income - @costs
      @gap = @costs && @savings && [ (@costs * @target_runway_months).round - @savings, 0 ].max
      annual = surplus && surplus * 12
      after = annual && annual - spend_cents
      before_state = state(surplus)
      {
        base_surplus_cents: surplus, annual_surplus_cents: annual, after_spend_surplus_cents: after,
        exceeds_annual_surplus: after && after.negative?,
        before: before_state, after: state(after && Rational(after, 12)),
        lift_cents: lift_cents, lift_split: @method.fetch("income_split").transform_values { |percent| (Rational(lift_cents * percent, 100)).round(2).to_f },
        lifted: state(lift_cents, base_surplus: surplus && surplus + lift_cents),
        targets: [ target("Emergency fund", before_state[:emergency_months], before_state[:emergency_tone], :emergency),
          target("Debt payoff", before_state[:debt_months], before_state[:debt_tone], :debt), surplus_target(surplus) ],
        priority_statuses: { emergency_fund: before_state[:emergency_tone], debt: before_state[:debt_tone],
          wealth: @wealth_tone, experiences: @gap && surplus && (before_state[:emergency_months] && before_state[:emergency_months] <= 24 ? "yellow" : "red") },
        windfall: WindfallSplit.new(amount_cents: windfall_cents, order: @method.fetch("windfall"),
          emergency_fund_gap_cents: @gap, consumer_debt_cents: @debt).call
      }
    end

    private

    def share(key) = Rational(@method.fetch("income_split").fetch(key), 100)
    def status = @method.fetch("status")

    def state(surplus, base_surplus: surplus)
      ef = emergency_months(surplus)
      debt = debt_months(surplus)
      { emergency_months: ef, emergency_tone: @gap && surplus && ReadinessCalculator.target_tone(ef, status),
        debt_months: debt, debt_tone: debt_known? && surplus ? ReadinessCalculator.target_tone(debt, status) : nil,
        surplus_tone: base_surplus && (base_surplus >= status.fetch("surplus_green_cents") ? "green" : base_surplus >= status.fetch("surplus_yellow_cents") ? "yellow" : "red") }
    end

    def emergency_months(lift)
      return nil unless @gap && lift
      return 0 if @gap.zero?

      allocation = [ lift, 0 ].max * share("emergency_fund")
      allocation.positive? ? (@gap / allocation).ceil : nil
    end

    def debt_known?
      @debt == 0 || (@debt && @debts && @debts.all? { |debt| debt.values_at(:balance_cents, :rate_percent, :minimum_cents).none?(&:nil?) })
    end

    # Fixed aggregate minimums, with freed payments and extra going to highest APR.
    # Monthly interest is calculated before payments; no invented APR or minimum.
    def debt_months(lift)
      return nil unless lift && debt_known?
      return 0 if @debt.zero?

      rows = @debts.sort_by { |debt| -debt[:rate_percent] }.map(&:dup)
      budget = rows.sum { |debt| debt[:minimum_cents] } + [ lift, 0 ].max * share("debt")
      1.upto(1200) do |month|
        rows.each { |debt| debt[:balance_cents] *= 1 + debt[:rate_percent].to_r / 1200 }
        left = budget
        rows.each do |debt|
          payment = [ debt[:minimum_cents], debt[:balance_cents] ].min
          debt[:balance_cents] -= payment
          left -= payment
        end
        rows.each do |debt|
          payment = [ left, debt[:balance_cents] ].min
          debt[:balance_cents] -= payment
          left -= payment
        end
        return month if rows.all? { |debt| debt[:balance_cents] <= 0 }
        # Bound precision without rounding payments to whole cents.
        rows.each { |debt| debt[:balance_cents] = debt[:balance_cents].to_f }
      end
      nil
    end

    def target(label, months, tone, kind)
      { label: label, months: months, tone: tone,
        yellow: requirement(required_lift(kind, status.fetch("target_yellow_months"))),
        green: requirement(required_lift(kind, status.fetch("target_green_months"))) }
    end

    def required_lift(kind, line)
      return nil if kind == :emergency && @gap.nil? || kind == :debt && !debt_known?

      calculate = kind == :emergency ? method(:emergency_months) : method(:debt_months)
      return 0 if calculate.call(0)&.<=(line)
      return nil if share(kind == :emergency ? "emergency_fund" : "debt").zero?

      low, high = 0, 1
      high *= 2 until calculate.call(high)&.<=(line) || high > Money::MAX_AMOUNT_CENTS
      return nil unless calculate.call(high)&.<=(line)

      while low < high
        mid = (low + high) / 2
        calculate.call(mid)&.<=(line) ? high = mid : low = mid + 1
      end
      low
    end

    def surplus_target(surplus)
      { label: "Base surplus", months: nil, tone: state(surplus)[:surplus_tone],
        yellow: requirement(surplus && [ status.fetch("surplus_yellow_cents") - surplus, 0 ].max),
        green: requirement(surplus && [ status.fetch("surplus_green_cents") - surplus, 0 ].max) }
    end

    def requirement(lift)
      { surplus_cents: lift, income_cents: lift && @income && @income + lift, extra_cents: lift }
    end
  end
end
