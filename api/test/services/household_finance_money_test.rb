require "test_helper"

class HouseholdFinanceMoneyTest < ActiveSupport::TestCase
  test "period conversions preserve exact annual totals" do
    annual = (1..12).sum { |month| HouseholdFinance::Money.period_cents(10_000, "annual", month: month) }
    weekly = (1..12).sum { |month| HouseholdFinance::Money.period_cents(12_345, "weekly", month: month) }
    biweekly = (1..12).sum { |month| HouseholdFinance::Money.period_cents(12_345, "biweekly", month: month) }

    assert_equal 10_000, annual
    assert_equal 12_345 * 52, weekly
    assert_equal 12_345 * 26, biweekly
  end
end
