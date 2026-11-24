require "test_helper"

class HouseholdFinanceToolCalculatorsTest < ActiveSupport::TestCase
  test "spend reduces surplus and delays the emergency target with method colours" do
    result = filter.call(spend_cents: 50_000)
    assert_equal 100_000, result[:base_surplus_cents]
    assert_equal 1_150_000, result[:after_spend_surplus_cents]
    assert_equal 24, result[:before][:emergency_months]
    assert_equal "yellow", result[:before][:emergency_tone]
    assert_equal 26, result[:after][:emergency_months]
    assert_equal "yellow", result[:after][:surplus_tone]
    assert_equal "yellow", result[:after][:emergency_tone]
  end

  test "flip requirements round up to cents and debt can be green" do
    targets = filter.call[:targets]
    assert_equal 0, targets[0][:yellow][:surplus_cents]
    assert_equal 100_000, targets[0][:green][:surplus_cents]
    assert_equal 600_000, targets[0][:green][:income_cents]
    assert_equal "green", targets[1][:tone]
    assert_equal 8, targets[1][:months]
    assert_equal 0, targets[1][:green][:surplus_cents]
    assert_equal 0, targets[2][:green][:extra_cents]
  end

  test "windfall uses shared waterfall and preserves cents" do
    result = filter.call(windfall_cents: 2_000_001)[:windfall]
    assert_equal [ 1_200_000, 600_000, 200_001 ], result.pluck(:cents)
    assert_equal %w[emergency_fund consumer_debt surplus], result.pluck(:key)
  end

  test "unknown facts remain unknown" do
    result = filter(savings: nil, debt: nil, income: nil).call(windfall_cents: 50_000)
    assert_nil result[:base_surplus_cents]
    assert_nil result[:before][:emergency_tone]
    assert_nil result[:targets][1][:green][:income_cents]
    assert_equal false, result[:windfall][0][:room_known]
    assert_nil runway(savings: nil)[:months]
    assert_nil runway(income: nil)[:monthly_draw_cents]
  end

  test "custom program lines change each target and waterfall" do
    method = CohortExperience::MethodSettings.defaults
    method["emergency_fund_months"] = 6
    method["status"]["target_green_months"] = 6
    method["status"]["target_yellow_months"] = 18
    result = HouseholdFinance::CfoFilterCalculator.new(income_cents: 500_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 600_000, method: method).call
    assert_equal 700_000, result[:targets][0][:green][:surplus_cents]
    assert_equal "red", result[:before][:emergency_tone]
  end

  test "runway prefills gap before draw and applies nominal monthly growth" do
    result = runway
    # Monthly growth 0.05/12; the final partial month is month 21.
    assert_equal 300_000, result[:monthly_gap_cents]
    assert_equal 300_000, result[:monthly_draw_cents]
    assert_equal 21, result[:months]
    assert_equal "yellow", result[:tone]
    assert_equal "Workable — move fast", result[:label]
  end

  test "runway boundaries are 18 and 36 months including the final partial month" do
    r = HouseholdFinance::OptionalityCalculator::MONTHLY_GROWTH
    [ [ 17, "red" ], [ 18, "yellow" ], [ 35, "yellow" ], [ 36, "green" ] ].each do |months, tone|
      savings = (300_000 * (1 - (1 + r)**(-months)) / r).floor
      result = runway(savings: savings)
      assert_equal months, result[:months]
      assert_equal tone, result[:tone]
    end
    assert_equal 0, runway(savings: 0)[:months]
    assert_equal 0, runway(savings: -10_000)[:months], "an overdrawn checking balance cannot give negative runway"
    assert runway(income: 400_000)[:sustainable]
    assert runway(draw: 0)[:no_draw]
    assert_nil runway(draw: 0)[:tone]
  end

  test "interest minimums zero shares lift split and excess annual spending" do
    method = CohortExperience::MethodSettings.defaults
    calculator = ->(rate) { HouseholdFinance::CfoFilterCalculator.new(income_cents: 500_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 100_000, debts: [ { balance_cents: 100_000, rate_percent: rate, minimum_cents: 10_000 } ], method: method) }
    # $1000 at 12% APR, $100/month: after ten payments $58.40 remains; eleven clears it.
    assert_equal 3, calculator.call(12).call[:lifted][:debt_months]
    assert_nil calculator.call(nil).call[:before][:debt_tone]
    assert_nil calculator.call(nil).call[:targets][1][:green][:extra_cents]
    result = filter.call(lift_cents: 200_000, spend_cents: 1_300_000)
    assert result[:exceeds_annual_surplus]
    assert_equal 8, result[:lifted][:emergency_months]
    assert_equal({ "emergency_fund" => 100_000.0, "debt" => 50_000.0, "surplus" => 50_000.0 }, result[:lift_split])
    assert_nil result[:priority_statuses][:wealth]
    assert_equal 3, filter(income: 1_400_000).call[:before][:emergency_months], "no $800 cap"
    method["income_split"] = { "emergency_fund" => 0, "debt" => 0, "surplus" => 100 }
    assert_nil calculator.call(12).call[:targets][0][:green][:extra_cents]
    assert_nil calculator.call(12).call[:before][:emergency_months]
  end

  test "debt lift is the smallest cent that pays interest and clears inside the colour line" do
    calculator = HouseholdFinance::CfoFilterCalculator.new(income_cents: 400_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 100_000,
      debts: [ { balance_cents: 100_000, rate_percent: 12, minimum_cents: 5_000 } ], method: CohortExperience::MethodSettings.defaults)
    # Twelve-month payment is $88.848788...; extra is $38.848788...;
    # with 25% to debt, the least whole-cent lift is $155.40.
    result = calculator.call
    assert_equal 15_540, result[:targets][1][:green][:extra_cents]
    assert_equal 12, calculator.call(lift_cents: 15_540)[:lifted][:debt_months]
    assert_equal 13, calculator.call(lift_cents: 15_539)[:lifted][:debt_months]
    assert_equal "green", calculator.call(lift_cents: 15_540)[:lifted][:debt_tone]
    assert_equal "yellow", calculator.call(lift_cents: 15_539)[:lifted][:debt_tone]
  end

  test "negative baseline and known unreachable requirements remain distinct" do
    assert_not filter(income: 300_000).call[:exceeds_annual_surplus]
    assert filter(income: 300_000).call(spend_cents: 1)[:exceeds_annual_surplus]
    assert_operator filter.call(lift_cents: 50_000)[:lifted][:emergency_months], :<, filter.call[:before][:emergency_months]
    method = CohortExperience::MethodSettings.defaults
    method["income_split"]["emergency_fund"] = 0
    result = HouseholdFinance::CfoFilterCalculator.new(income_cents: 500_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 0, method: method).call
    assert_includes result[:targets][0][:green][:reason], "Can't be reached"
  end

  test "runway missing reasons zero draw and exact final month" do
    assert_equal "Add replacement income", runway(income: nil)[:label]
    assert_equal "No savings to draw from", runway(savings: 0)[:label]
    assert_nil runway(draw: 0)[:tone]
    assert_equal 3_600_000, runway(draw: 0)[:business_required_annual_cents]
    r = HouseholdFinance::OptionalityCalculator::MONTHLY_GROWTH
    savings = (300_000 * (1 - (1 + r)**(-1200)) / r).floor
    assert_equal 1200, runway(savings: savings)[:months]
  end

  test "known arrears are a one-time catch-up paid before extra avalanche principal" do
    method = CohortExperience::MethodSettings.defaults
    debts = [
      { balance_cents: 200_000, rate_percent: 29.99, minimum_cents: 5_000, past_due_cents: nil },
      { balance_cents: 300_000, rate_percent: 5, minimum_cents: 10_000, past_due_cents: 50_000 }
    ]
    build = ->(income, debt_rows, catch_up) { HouseholdFinance::CfoFilterCalculator.new(income_cents: income, costs_cents: 400_000, savings_cents: 0,
      debt_cents: 500_000, debts: debt_rows, method: method, catch_up_cents: catch_up) }

    # $400 surplus, 25% to debt: $100 a month after the minimums catches up the $500 in five months.
    funded = build.call(440_000, debts, 50_000).call(spend_cents: 400_000)
    assert_equal 5, funded[:before][:catch_up_months]
    assert_equal 50_000, funded[:catch_up_cents]
    assert_equal 4_000_00 * 12 / 10 - 50_000 - 400_000, funded[:after_spend_surplus_cents], "the catch-up comes out of the year's surplus before a spend"
    # The recurring baseline is unchanged: same base surplus and emergency-fund gap months.
    plain = build.call(440_000, debts.map { |row| row.merge(past_due_cents: nil) }, 0).call
    assert_equal plain[:base_surplus_cents], funded[:base_surplus_cents]
    assert_equal plain[:before][:emergency_months], funded[:before][:emergency_months]
    assert_nil plain[:before][:catch_up_months]
    assert_operator funded[:before][:debt_months], :>=, plain[:before][:debt_months], "catching up the 5% loan delays the 29.99% card"

    # Zero or negative surplus: nothing is left after the minimums, so the arrears carry
    # forward until a paid-off card's minimum frees cash; never caught up in month one.
    [ 400_000, 350_000 ].each do |income|
      stuck = build.call(income, debts, 50_000).call(spend_cents: 10_000)
      assert_operator stuck[:before][:catch_up_months], :>, 12, income
      assert stuck[:exceeds_annual_surplus], "a spend cannot come before the catch-up"
    end

    # A windfall below the arrears goes entirely to the catch-up once the fund is full.
    small = HouseholdFinance::CfoFilterCalculator.new(income_cents: 440_000, costs_cents: 400_000, savings_cents: 10_000_000,
      debt_cents: 500_000, debts: debts, method: method, catch_up_cents: 50_000).call(windfall_cents: 20_000)[:windfall]
    assert_equal [ [ "consumer_debt_catch_up", 20_000 ] ], small.map { |step| [ step[:key], step[:cents] ] }
  end

  test "debt never payoff and the 1200 month boundary are distinct" do
    build = ->(balance, rate, minimum) { HouseholdFinance::CfoFilterCalculator.new(income_cents: 400_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: balance, debts: [ { balance_cents: balance, rate_percent: rate, minimum_cents: minimum } ], method: CohortExperience::MethodSettings.defaults).call }
    assert_equal "never", build.call(100_000, 12, 1)[:before][:debt_timing]
    assert_equal 1200, build.call(1_200_000, 0, 1000)[:before][:debt_months]
    assert_equal "beyond_limit", build.call(1_201_000, 0, 1000)[:before][:debt_timing]
  end

  test "growing aggregate debt can still recover when a high APR minimum is freed" do
    result = HouseholdFinance::CfoFilterCalculator.new(income_cents: 400_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 1_300_000, method: CohortExperience::MethodSettings.defaults,
      debts: [ { balance_cents: 100_000, rate_percent: 120, minimum_cents: 15_000 },
        { balance_cents: 1_200_000, rate_percent: 12, minimum_cents: 100 } ]).call
    assert_not_nil result[:before][:debt_months]
  end

  test "capped target is known and repeated amortization is cached" do
    method = CohortExperience::MethodSettings.defaults
    result = HouseholdFinance::CfoFilterCalculator.new(income_cents: 0, costs_cents: HouseholdFinance::Money::MAX_AMOUNT_CENTS,
      savings_cents: 0, debt_cents: 0, target_runway_months: 100, method: method).call
    assert_includes result[:targets][0][:green][:reason], "Needs more than $9,999,999.99"
    calculator = filter
    calls = Hash.new(0)
    original = calculator.method(:amortize_debt)
    calculator.define_singleton_method(:amortize_debt) { |lift, limit:| calls[[ lift, limit ]] += 1; original.call(lift, limit: limit) }
    calculator.call
    assert calls.values.all? { |count| count == 1 }
  end

  test "income lifts cover the existing deficit before funding targets" do
    calculator = HouseholdFinance::CfoFilterCalculator.new(income_cents: 400_000, costs_cents: 450_000,
      savings_cents: 0, debt_cents: 0, method: CohortExperience::MethodSettings.defaults)
    result = calculator.call(spend_cents: 10_000, lift_cents: 275_000)
    assert_equal(-50_000, result[:base_surplus_cents])
    assert_equal(-610_000, result[:after_spend_surplus_cents])
    assert_equal 275_000, result[:targets][0][:green][:extra_cents]
    assert_equal 12, result[:lifted][:emergency_months]
    assert_equal 13, calculator.call(lift_cents: 274_999)[:lifted][:emergency_months]
    assert_nil calculator.call(lift_cents: 50_000)[:lifted][:emergency_months]
  end

  private

  def filter(savings: 0, debt: 600_000, income: 500_000)
    HouseholdFinance::CfoFilterCalculator.new(income_cents: income, costs_cents: 400_000,
      savings_cents: savings, debt_cents: debt, debts: debt && [ { balance_cents: debt, rate_percent: 0, minimum_cents: 50_000 } ], method: CohortExperience::MethodSettings.defaults)
  end

  def runway(savings: 6_000_000, income: 100_000, draw: nil)
    HouseholdFinance::OptionalityCalculator.new(savings_cents: savings, monthly_costs_cents: 400_000,
      replacement_income_cents: income, monthly_draw_cents: draw).call
  end
end
