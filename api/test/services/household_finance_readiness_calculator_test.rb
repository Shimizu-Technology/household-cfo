require "test_helper"

class HouseholdFinanceReadinessCalculatorTest < ActiveSupport::TestCase
  test "derives every readiness number from category outflow plus debt minimums" do
    result = calculate(monthly_income_cents: 825_000, category_outflow_cents: 692_500, debt_minimums_cents: 92_000, protected_liquid_cents: 2_509_000)

    assert_equal 784_500, result.fetch(:total_outflow_cents)
    assert_equal 40_500, result.fetch(:baseline_surplus_cents)
    assert_equal 3.2, result.fetch(:runway_months)
    # Six months is $47,070; $21,980 short at $405 a month is 55 months, beyond the 36-month Yellow line.
    assert_equal 4_707_000, result.fetch(:emergency_fund_target_cents)
    assert_equal 2_198_000, result.fetch(:emergency_fund_gap_cents)
    assert_equal 55, result.fetch(:months_to_target)
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal "Red — emergency fund target more than 36 months away", result.fetch(:readiness_label)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
    assert_equal "red", result.fetch(:surplus_tone)
    assert_equal "Red — monthly surplus below $500", result.fetch(:surplus_label)
  end

  test "a target is Green within 12 months, Yellow within 36, Red beyond" do
    # $1,000 a month of costs, six-month target $6,000, nothing saved.
    assert_equal [ "green", 12 ], tone_and_months(surplus_cents: 50_000)
    assert_equal [ "yellow", 13 ], tone_and_months(surplus_cents: 46_154)
    assert_equal [ "yellow", 36 ], tone_and_months(surplus_cents: 16_667)
    assert_equal [ "red", 37 ], tone_and_months(surplus_cents: 16_666)
    assert_equal [ "red", nil ], tone_and_months(surplus_cents: 0)
    assert_equal [ "red", nil ], tone_and_months(surplus_cents: -10_000)
  end

  test "a reached target is Green whatever the surplus" do
    result = calculate(monthly_income_cents: 90_000, category_outflow_cents: 100_000, protected_liquid_cents: 600_000)

    assert_equal 0, result.fetch(:months_to_target)
    assert_equal "green", result.fetch(:readiness_tone)
    assert_equal "Green — emergency fund target reached", result.fetch(:readiness_label)
    assert_equal "red", result.fetch(:surplus_tone)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "monthly surplus is Green at $1,000, Yellow at $500" do
    assert_equal "green", calculate(monthly_income_cents: 200_000, category_outflow_cents: 100_000).fetch(:surplus_tone)
    assert_equal "yellow", calculate(monthly_income_cents: 199_999, category_outflow_cents: 100_000).fetch(:surplus_tone)
    assert_equal "yellow", calculate(monthly_income_cents: 150_000, category_outflow_cents: 100_000).fetch(:surplus_tone)
    assert_equal "red", calculate(monthly_income_cents: 149_999, category_outflow_cents: 100_000).fetch(:surplus_tone)
  end

  test "a program's status rule changes the colours" do
    status = { "target_green_months" => 6, "target_yellow_months" => 12, "surplus_green_cents" => 300_000, "surplus_yellow_cents" => 200_000 }
    default = calculate(monthly_income_cents: 150_000, category_outflow_cents: 100_000)
    changed = calculate(monthly_income_cents: 150_000, category_outflow_cents: 100_000, status: status)

    assert_equal [ "green", "yellow" ], [ default.fetch(:readiness_tone), default.fetch(:surplus_tone) ]
    assert_equal [ "yellow", "red" ], [ changed.fetch(:readiness_tone), changed.fetch(:surplus_tone) ]
    # Both colours need the whole $500 surplus ($6,000 in 12 months), so nothing is safe to spend.
    assert_equal [ 0, 0 ], [ default.fetch(:safe_to_spend_cents), changed.fetch(:safe_to_spend_cents) ]
    assert_equal "Yellow — emergency fund target within 12 months", changed.fetch(:readiness_label)
    assert_equal "Red — monthly surplus below $2,000", changed.fetch(:surplus_label)
    assert_equal status, changed.fetch(:status_rule)
  end

  test "safe to spend never makes the shown colour untrue" do
    # $1,000 a month of costs, nothing saved, 3-month target: $3,000 gap.
    # $250 surplus reaches it in 12 months (Green) only if all $250 goes to it.
    tight = calculate(monthly_income_cents: 125_000, category_outflow_cents: 100_000, target_runway_months: 3)
    assert_equal [ "green", 12, 0 ], [ tight.fetch(:readiness_tone), tight.fetch(:months_to_target), tight.fetch(:safe_to_spend_cents) ]

    # $300 surplus: Green needs $250 a month, so $50 is safe (40% would be $120).
    roomy = calculate(monthly_income_cents: 130_000, category_outflow_cents: 100_000, target_runway_months: 3)
    assert_equal [ "green", 5_000 ], [ roomy.fetch(:readiness_tone), roomy.fetch(:safe_to_spend_cents) ]
    assert_equal "green", tone_after_spending(roomy)
    assert_equal "yellow", tone_after_spending(roomy.merge(safe_to_spend_cents: 5_001))

    # Yellow keeps Yellow: $3,000 over 36 months needs $83.34, so $100 leaves $16.66 safe (40% would be $40).
    yellow = calculate(monthly_income_cents: 110_000, category_outflow_cents: 100_000, target_runway_months: 3)
    assert_equal [ "yellow", 30, 1_666 ], [ yellow.fetch(:readiness_tone), yellow.fetch(:months_to_target), yellow.fetch(:safe_to_spend_cents) ]
    assert_equal "yellow", tone_after_spending(yellow)
    assert_equal "red", tone_after_spending(yellow.merge(safe_to_spend_cents: 1_667))
  end

  test "a reached target keeps the forty percent safe to spend" do
    result = calculate(monthly_income_cents: 130_000, category_outflow_cents: 100_000, protected_liquid_cents: 300_000, target_runway_months: 3)

    assert_equal [ "green", 0, 12_000 ], [ result.fetch(:readiness_tone), result.fetch(:emergency_fund_gap_cents), result.fetch(:safe_to_spend_cents) ]
  end

  test "returns red and zero safe to spend when outflow exceeds income" do
    result = calculate(monthly_income_cents: 500_000, category_outflow_cents: 480_000, debt_minimums_cents: 40_000, protected_liquid_cents: 2_000_000)

    assert_equal(-20_000, result.fetch(:baseline_surplus_cents))
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal "Red — bring planned costs within income to build the emergency fund", result.fetch(:readiness_label)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "handles a zero outflow without dividing by zero" do
    result = calculate(monthly_income_cents: 0, category_outflow_cents: 0, protected_liquid_cents: 50_000)

    assert_equal 0.0, result.fetch(:runway_months)
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "no planned costs says setup is incomplete, not that a $0 target is far away" do
    result = calculate(monthly_income_cents: 300_000, category_outflow_cents: 0)

    assert_equal 0, result.fetch(:emergency_fund_target_cents)
    assert_equal "Setup incomplete — add planned monthly costs to set the emergency fund target", result.fetch(:readiness_label)
    assert_no_match(/months away/, result.fetch(:readiness_label))
  end

  test "does not round runway up onto an unmet target" do
    result = calculate(monthly_income_cents: 101_000, category_outflow_cents: 100_000, protected_liquid_cents: 599_999)

    assert_equal 5.9, result.fetch(:runway_months)
    assert_equal 1, result.fetch(:emergency_fund_gap_cents)
    assert_equal 1, result.fetch(:months_to_target)
  end

  test "reaches the exact target without requiring an extra cent" do
    result = calculate(monthly_income_cents: 100_000, category_outflow_cents: 100_000, protected_liquid_cents: 600_000)

    assert_equal 6.0, result.fetch(:runway_months)
    assert_equal 0, result.fetch(:emergency_fund_gap_cents)
    assert_equal "green", result.fetch(:readiness_tone)
  end

  test "safe to spend is forty percent of the surplus when that still keeps the colour" do
    # $3,000 gap at $1,000 a month: Green needs only $250 a month, so 40% ($400) keeps Green.
    result = calculate(monthly_income_cents: 200_000, category_outflow_cents: 100_000, protected_liquid_cents: 300_000)

    assert_equal "green", result.fetch(:readiness_tone)
    assert_equal 40_000, result.fetch(:safe_to_spend_cents)
    assert_equal "green", tone_after_spending(result)
  end

  private

  def calculate(monthly_income_cents:, category_outflow_cents:, debt_minimums_cents: 0, protected_liquid_cents: 0, target_runway_months: 6, **options)
    HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: monthly_income_cents, category_outflow_cents: category_outflow_cents, debt_minimums_cents: debt_minimums_cents,
      protected_liquid_cents: protected_liquid_cents, target_runway_months: target_runway_months, **options
    ).call
  end

  # The colour if the household spends its safe-to-spend and the rest goes to the target.
  def tone_after_spending(result)
    months = HouseholdFinance::ReadinessCalculator.months_to_reach(result.fetch(:emergency_fund_gap_cents), result.fetch(:baseline_surplus_cents) - result.fetch(:safe_to_spend_cents))
    HouseholdFinance::ReadinessCalculator.target_tone(months, result.fetch(:status_rule))
  end

  def tone_and_months(surplus_cents:)
    result = calculate(monthly_income_cents: 100_000 + surplus_cents, category_outflow_cents: 100_000)
    [ result.fetch(:readiness_tone), result.fetch(:months_to_target) ]
  end
end
