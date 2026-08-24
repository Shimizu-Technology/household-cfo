require "test_helper"

class HouseholdFinanceReadinessCalculatorTest < ActiveSupport::TestCase
  test "derives every readiness number from category outflow plus debt minimums" do
    result = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 825_000,
      category_outflow_cents: 692_500,
      debt_minimums_cents: 92_000,
      protected_liquid_cents: 2_509_000,
      target_runway_months: 6
    ).call

    assert_equal 784_500, result.fetch(:total_outflow_cents)
    assert_equal 40_500, result.fetch(:baseline_surplus_cents)
    assert_equal 3.2, result.fetch(:runway_months)
    assert_equal "yellow", result.fetch(:readiness_tone)
    assert_equal "Yellow — close, but protect runway", result.fetch(:readiness_label)
    assert_equal 16_200, result.fetch(:safe_to_spend_cents)
    assert_equal 2_353_500, result.fetch(:yellow_runway_target_cents)
    assert_equal 0, result.fetch(:yellow_runway_gap_cents)
    assert_equal 4_707_000, result.fetch(:green_runway_target_cents)
    assert_equal 2_198_000, result.fetch(:green_runway_gap_cents)
  end

  test "returns red and zero safe to spend when outflow exceeds income" do
    result = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 500_000,
      category_outflow_cents: 480_000,
      debt_minimums_cents: 40_000,
      protected_liquid_cents: 2_000_000,
      target_runway_months: 6
    ).call

    assert_equal(-20_000, result.fetch(:baseline_surplus_cents))
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "handles a zero outflow without dividing by zero" do
    result = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 0,
      category_outflow_cents: 0,
      debt_minimums_cents: 0,
      protected_liquid_cents: 50_000,
      target_runway_months: 6
    ).call

    assert_equal 0.0, result.fetch(:runway_months)
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "does not unlock yellow readiness by rounding runway up" do
    result = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 200_000,
      category_outflow_cents: 100_000,
      debt_minimums_cents: 0,
      protected_liquid_cents: 299_999,
      target_runway_months: 6
    ).call

    assert_equal 3.0, result.fetch(:runway_months)
    assert_equal 1, result.fetch(:yellow_runway_gap_cents)
    assert_equal "red", result.fetch(:readiness_tone)
    assert_equal 0, result.fetch(:safe_to_spend_cents)
  end

  test "reaches exact runway thresholds without requiring an extra cent" do
    yellow = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 200_000,
      category_outflow_cents: 100_000,
      debt_minimums_cents: 0,
      protected_liquid_cents: 300_000,
      target_runway_months: 6
    ).call
    green = HouseholdFinance::ReadinessCalculator.new(
      monthly_income_cents: 200_000,
      category_outflow_cents: 100_000,
      debt_minimums_cents: 0,
      protected_liquid_cents: 600_000,
      target_runway_months: 6
    ).call

    assert_equal "yellow", yellow.fetch(:readiness_tone)
    assert_equal "green", green.fetch(:readiness_tone)
  end
end
