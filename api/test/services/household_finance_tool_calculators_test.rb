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
    assert_equal 66_667, targets[0][:yellow][:surplus_cents]
    assert_equal 200_000, targets[0][:green][:surplus_cents]
    assert_equal 700_000, targets[0][:green][:income_cents]
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
    assert_equal 800_000, result[:targets][0][:green][:surplus_cents]
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
    assert runway(draw: 0)[:sustainable]
  end

  test "interest minimums zero shares lift split and excess annual spending" do
    method = CohortExperience::MethodSettings.defaults
    calculator = ->(rate) { HouseholdFinance::CfoFilterCalculator.new(income_cents: 500_000, costs_cents: 400_000,
      savings_cents: 0, debt_cents: 100_000, debts: [ { balance_cents: 100_000, rate_percent: rate, minimum_cents: 10_000 } ], method: method) }
    # $1000 at 12% APR, $100/month: after ten payments $58.40 remains; eleven clears it.
    assert_equal 11, calculator.call(12).call[:lifted][:debt_months]
    assert_nil calculator.call(nil).call[:before][:debt_tone]
    assert_nil calculator.call(nil).call[:targets][1][:green][:extra_cents]
    result = filter.call(lift_cents: 200_000, spend_cents: 1_300_000)
    assert result[:exceeds_annual_surplus]
    assert_equal 12, result[:lifted][:emergency_months]
    assert_equal({ "emergency_fund" => 100_000.0, "debt" => 50_000.0, "surplus" => 50_000.0 }, result[:lift_split])
    assert_nil result[:priority_statuses][:wealth]
    assert_equal 3, filter(income: 1_400_000).call[:before][:emergency_months], "no $800 cap"
    method["income_split"] = { "emergency_fund" => 0, "debt" => 0, "surplus" => 100 }
    assert_nil calculator.call(12).call[:targets][0][:green][:extra_cents]
    assert_nil calculator.call(12).call[:before][:emergency_months]
  end

  test "debt lift is the smallest cent that pays interest and clears inside the colour line" do
    calculator = HouseholdFinance::CfoFilterCalculator.new(income_cents: 500_000, costs_cents: 400_000,
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
