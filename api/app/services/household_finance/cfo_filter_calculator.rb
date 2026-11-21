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
      @base = surplus
      @debt_months_cache = {}
      @debt_outcomes = {}
      @gap = @costs && @savings && [ (@costs * @target_runway_months).round - @savings, 0 ].max
      annual = surplus && surplus * 12
      after = annual && annual - spend_cents
      before_state = state(surplus)
      {
        base_surplus_cents: surplus, annual_surplus_cents: annual, after_spend_surplus_cents: after,
        exceeds_annual_surplus: spend_cents.positive? && after && after.negative?,
        before: before_state, after: state(after && Rational(after, 12)),
        lift_cents: lift_cents, lift_split: @method.fetch("income_split").transform_values { |percent| (Rational(lift_cents * percent, 100)).round(2).to_f },
        lifted: state(@base && @base + lift_cents, base_surplus: surplus && surplus + lift_cents),
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
        debt_months: debt, debt_timing: debt.nil? && debt_known? ? @debt_outcomes[surplus] : nil, debt_tone: debt_known? && surplus ? ReadinessCalculator.target_tone(debt, status) : nil,
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
    def debt_months(lift, limit: 1200)
      return nil unless lift && debt_known?
      return 0 if @debt.zero?

      key = [ lift, limit ]
      return @debt_months_cache[key] if @debt_months_cache.key?(key)

      @debt_months_cache[key] = amortize_debt(lift, limit: limit)
    end

    def amortize_debt(lift, limit:)
      # Integer numerators share a denominator: preserve fractional cents
      # exactly without Rational arithmetic in the amortization loop.
      rates = @debts.map { |debt| debt[:rate_percent].to_r / 1200 }
      factor = rates.map(&:denominator).reduce(1, :lcm)
      rows = @debts.zip(rates).sort_by { |_, rate| -rate }.map do |debt, rate|
        { balance: debt[:balance_cents] * 1200, minimum: debt[:minimum_cents],
          interest: rate.numerator * (factor / rate.denominator) }
      end
      denominator = 1200
      budget = @debts.sum { |debt| debt[:minimum_cents] } + [ lift, 0 ].max * share("debt")
      budget_numerator, budget_denominator = budget.numerator, budget.denominator
      1.upto(limit) do |month|
        previous_balances = rows.map { |debt| debt[:balance] * factor }
        denominator *= factor
        rows.each { |debt| debt[:balance] *= factor + debt[:interest] }
        left = budget_numerator * denominator / budget_denominator
        rows.each do |debt|
          payment = [ debt[:minimum] * denominator, debt[:balance] ].min
          debt[:balance] -= payment
          left -= payment
        end
        rows.each do |debt|
          payment = [ left, debt[:balance] ].min
          debt[:balance] -= payment
          left -= payment
        end
        if rows.zip(previous_balances).all? { |debt, previous| debt[:balance] >= previous }
          @debt_outcomes[lift] = "never"
          return nil
        end
        return month if rows.all? { |debt| debt[:balance] <= 0 }
      end
      @debt_outcomes[lift] = "beyond_limit"
      nil
    end

    def target(label, months, tone, kind)
      { label: label, months: months, tone: tone,
        yellow: target_requirement(kind, status.fetch("target_yellow_months")),
        green: target_requirement(kind, status.fetch("target_green_months")) }
    end

    def target_requirement(kind, line)
      lift = required_lift(kind, line)
      reason = if lift.nil?
        if @base.nil? || (kind == :emergency ? @gap.nil? : !debt_known?)
          "Add the missing approved balances and plan details"
        elsif share(kind == :emergency ? "emergency_fund" : "debt").zero?
          "Can't be reached with this program's split"
        else
          "Needs more than #{Money::MAX_AMOUNT_TEXT} a month"
        end
      end
      requirement(lift).merge(reason: reason)
    end

    def required_lift(kind, line)
      return nil if @base.nil? || kind == :emergency && @gap.nil? || kind == :debt && !debt_known?

      calculate = ->(lift) { kind == :emergency ? emergency_months(@base + lift) : debt_months(@base + lift, limit: line) }
      return 0 if calculate.call(0)&.<=(line)
      return nil if share(kind == :emergency ? "emergency_fund" : "debt").zero?

      low, high = 0, 1
      high = [ high * 2, Money::MAX_AMOUNT_CENTS ].min until calculate.call(high)&.<=(line) || high == Money::MAX_AMOUNT_CENTS
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
