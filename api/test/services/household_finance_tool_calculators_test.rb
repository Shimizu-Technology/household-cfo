require "test_helper"

class HouseholdFinanceToolCalculatorsTest < ActiveSupport::TestCase
  test "spend reduces surplus and delays the emergency target with method colours" do
    result = filter.call(spend_cents: 50_000)
    assert_equal 100_000, result[:base_surplus_cents]
    assert_equal 50_000, result[:after_spend_surplus_cents]
    assert_equal 12, result[:before][:emergency_months]
    assert_equal "green", result[:before][:emergency_tone]
    assert_equal 24, result[:after][:emergency_months]
    assert_equal "yellow", result[:after][:surplus_tone]
    assert_equal "yellow", result[:after][:emergency_tone]
  end

  test "flip requirements round up to cents and debt can be green" do
    targets = filter.call[:targets]
    assert_equal 33_334, targets[0][:yellow][:surplus_cents]
    assert_equal 100_000, targets[0][:green][:surplus_cents]
    assert_equal 500_000, targets[0][:green][:income_cents]
    assert_equal "green", targets[1][:tone]
    assert_equal 6, targets[1][:months]
    assert_equal 50_000, targets[1][:green][:surplus_cents]
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
    assert_equal 400_000, result[:targets][0][:green][:surplus_cents]
    assert_equal "red", result[:before][:emergency_tone]
  end

  test "runway prefills gap before draw and applies effective annual growth" do
    result = runway
    # $4,000 costs - $1,000 replacement = $3,000 draw. $60k funds 20 full
    # months: balance after 20 is $2,702.86; after 21 it would be -$286.12.
    assert_equal 300_000, result[:monthly_gap_cents]
    assert_equal 300_000, result[:monthly_draw_cents]
    assert_equal 20, result[:months]
    assert_equal "yellow", result[:tone]
    assert_equal "Workable — move fast", result[:label]
  end

  test "runway boundaries are 18 and 36 fully funded months" do
    r = HouseholdFinance::OptionalityCalculator::MONTHLY_GROWTH
    [ [ 17, "red" ], [ 18, "yellow" ], [ 35, "yellow" ], [ 36, "green" ] ].each do |months, tone|
      savings = (300_000 * (1 - (1 + r)**(-months)) / r).ceil
      result = runway(savings: savings)
      assert_equal months, result[:months]
      assert_equal tone, result[:tone]
    end
    assert_equal 0, runway(savings: 0)[:months]
    assert_equal 0, runway(savings: -10_000)[:months], "an overdrawn checking balance cannot give negative runway"
    assert runway(income: 400_000)[:sustainable]
    assert runway(draw: 0)[:sustainable]
  end

  private

  def filter(savings: 0, debt: 600_000, income: 500_000)
    HouseholdFinance::CfoFilterCalculator.new(income_cents: income, costs_cents: 400_000,
      savings_cents: savings, debt_cents: debt, method: CohortExperience::MethodSettings.defaults)
  end

  def runway(savings: 6_000_000, income: 100_000, draw: nil)
    HouseholdFinance::OptionalityCalculator.new(savings_cents: savings, monthly_costs_cents: 400_000,
      replacement_income_cents: income, monthly_draw_cents: draw).call
  end
end
