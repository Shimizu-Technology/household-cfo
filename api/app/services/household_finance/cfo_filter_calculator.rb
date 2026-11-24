# frozen_string_literal: true

module HouseholdFinance
  # Request-local comparisons. Rational cents preserve the annual split exactly.
  #
  # Known consumer-debt arrears (catch_up_cents, each debt row's past_due_cents) are a
  # one-time obligation: a spend must fit the year's surplus after the catch-up, and
  # debt-payment cash catches them up before any extra avalanche principal. Recurring
  # costs, the base surplus and the emergency-fund target stay on the recurring baseline.
  class CfoFilterCalculator
    # debt_conflicts: DebtArrears#conflicts. While any exist, the total debt is unknown,
    # so no payoff estimate or debt-free reading is given; known arrears still come first.
    def initialize(income_cents:, costs_cents:, savings_cents:, debt_cents:, method:, target_runway_months: nil, debts: nil, wealth_tone: nil, catch_up_cents: 0, debt_conflicts: [])
      @debt_conflicts = Array(debt_conflicts)
      debt_cents = nil if @debt_conflicts.any?
      @income, @costs, @savings, @debt, @method = income_cents, costs_cents, savings_cents, debt_cents, method
      @debts, @wealth_tone = debts, wealth_tone
      @catch_up = catch_up_cents.to_i
      @target_runway_months = target_runway_months || method.fetch("emergency_fund_months")
    end

    def call(spend_cents: 0, windfall_cents: 0, lift_cents: 0)
      surplus = @income && @costs && @income - @costs
      @base = surplus
      @debt_months_cache = {}
      @debt_outcomes = {}
      @catch_up_months = {}
      @gap = @costs && @savings && [ (@costs * @target_runway_months).round - @savings, 0 ].max
      annual = surplus && surplus * 12
      # The catch-up is owed once, from this year's surplus, before money is free to spend.
      after = annual && annual - @catch_up - spend_cents
      before_state = state(surplus)
      {
        base_surplus_cents: surplus, annual_surplus_cents: annual, catch_up_cents: @catch_up, after_spend_surplus_cents: after,
        debt_records_conflict: @debt_conflicts,
        exceeds_annual_surplus: spend_cents.positive? && after && after.negative?,
        # The monthly projection pays the catch-up inside the debt budget, so it is not
        # taken from the monthly surplus a second time here.
        before: before_state, after: state(annual && Rational(annual - spend_cents, 12)),
        lift_cents: lift_cents, lift_split: @method.fetch("income_split").transform_values { |percent| (Rational(lift_cents * percent, 100)).round(2).to_f },
        lifted: state(@base && @base + lift_cents, base_surplus: surplus && surplus + lift_cents),
        targets: [ target("Emergency fund", before_state[:emergency_months], before_state[:emergency_tone], :emergency),
          target("Debt payoff", before_state[:debt_months], before_state[:debt_tone], :debt), surplus_target(surplus) ],
        priority_statuses: { emergency_fund: before_state[:emergency_tone], debt: before_state[:debt_tone],
          wealth: @wealth_tone, experiences: @gap && surplus && (before_state[:emergency_months] && before_state[:emergency_months] <= 24 ? "yellow" : "red") },
        windfall: WindfallSplit.new(amount_cents: windfall_cents, order: @method.fetch("windfall"),
          emergency_fund_gap_cents: @gap, consumer_debt_cents: @debt, catch_up_cents: @catch_up).call
      }
    end

    private

    def share(key) = Rational(@method.fetch("income_split").fetch(key), 100)
    def status = @method.fetch("status")

    def state(surplus, base_surplus: surplus)
      ef = emergency_months(surplus)
      debt = debt_months(surplus)
      { emergency_months: ef, emergency_tone: @gap && surplus && ReadinessCalculator.target_tone(ef, status),
        catch_up_months: debt_known? && surplus && @catch_up.positive? ? @catch_up_months[[ surplus, 1200 ]] : nil,
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
    # Cash left after the minimums catches up known past-due amounts first (lowering the
    # same balance, unpaid arrears carried to the next month), then goes to principal.
    def debt_months(lift, limit: 1200)
      return nil unless lift && debt_known?
      return 0 if @debt.zero?

      key = [ lift, limit ]
      return @debt_months_cache[key] if @debt_months_cache.key?(key)

      @debt_months_cache[key] = amortize_debt(lift, limit: limit)
    end

    def amortize_debt(lift, limit:)
      key = [ lift, limit ]
      # Integer numerators share a denominator: preserve fractional cents
      # exactly without Rational arithmetic in the amortization loop.
      rates = @debts.map { |debt| debt[:rate_percent].to_r / 1200 }
      factor = rates.map(&:denominator).reduce(1, :lcm)
      rows = @debts.zip(rates).sort_by { |_, rate| -rate }.map do |debt, rate|
        arrears = [ debt[:past_due_cents].to_i, debt[:balance_cents] ].min
        { balance: debt[:balance_cents] * 1200, minimum: debt[:minimum_cents], arrears: [ arrears, 0 ].max * 1200,
          interest: rate.numerator * (factor / rate.denominator) }
      end
      behind = rows.any? { |debt| debt[:arrears].positive? }
      denominator = 1200
      budget = @debts.sum { |debt| debt[:minimum_cents] } + [ lift, 0 ].max * share("debt")
      budget_numerator, budget_denominator = budget.numerator, budget.denominator
      1.upto(limit) do |month|
        previous_balances = rows.map { |debt| debt[:balance] * factor }
        denominator *= factor
        rows.each { |debt| debt[:balance] *= factor + debt[:interest]; debt[:arrears] *= factor }
        left = budget_numerator * denominator / budget_denominator
        rows.each do |debt|
          payment = [ debt[:minimum] * denominator, debt[:balance] ].min
          debt[:balance] -= payment
          left -= payment
        end
        rows.each do |debt|
          payment = [ left, debt[:arrears], debt[:balance] ].min
          debt[:balance] -= payment
          debt[:arrears] = [ debt[:arrears] - payment, debt[:balance] ].min
          left -= payment
        end
        if behind && rows.all? { |debt| debt[:arrears] <= 0 }
          @catch_up_months[key] = month
          behind = false
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
