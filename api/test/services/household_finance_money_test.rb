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

  test "chat amounts read k and thousand as thousands, never as single dollars" do
    pattern = HouseholdFinance::Money::CHAT_DOLLAR_AMOUNT_PATTERN
    {
      "$5k" => 500_000, "$1.5k" => 150_000, "$2K" => 200_000, "$3 thousand" => 300_000, "$3 Thousand" => 300_000,
      "$5,000" => 500_000, "$12.50" => 1_250, "$5k." => 500_000, "$1,250.50 today" => 125_050,
      "$5 kids meal" => 500, "$5km" => 500, "$5 K-mart" => 500, "$5kmart" => 500
    }.each do |text, cents|
      match = text.match(pattern)
      assert match, text
      assert_equal cents, HouseholdFinance::Money.chat_cents(match[1]), text
    end
    assert_equal "5000", HouseholdFinance::Money.chat_amount_text("5k")
    assert_equal "1500", HouseholdFinance::Money.chat_amount_text("1.5K")
    assert_equal "12.50", HouseholdFinance::Money.chat_amount_text("12.50")
    assert_equal "1250", HouseholdFinance::Money.chat_amount_text("1,250")
  end
end
