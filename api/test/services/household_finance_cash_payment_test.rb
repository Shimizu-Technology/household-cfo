require "test_helper"

# Invented receipt and chat text only. Cash is known only from what she or her receipt said (decision 3).
class HouseholdFinanceCashPaymentTest < ActiveSupport::TestCase
  def cash(total_cents, *texts) = HouseholdFinance::ReceiptTenders.cash_cents(total_cents: total_cents, texts: texts)

  test "a receipt paid in cash, less the change, is cash" do
    assert_equal 4042, cash(4042, "Lunch special 40.42; TOTAL $40.42; Cash $50.00; Change due $9.58")
    assert_equal 1875, cash(1875, "Paid $18.75 in cash")
  end

  test "a receipt paid partly in cash names only its cash part" do
    assert_equal 2000, cash(6000, "TOTAL $60.00; Cash $20.00; Debit card 7302 $40.00")
    assert_equal 1000, cash(3000, "Loyalty points $20.00; Cash $10.00")
  end

  test "card, Apple Cash, Cash App, cash back, refunds and unbalanced lines are not cash" do
    assert_nil cash(3488, "TOTAL $34.88; Debit card 7302 $34.88")
    assert_nil cash(1875, "Apple Cash $18.75")
    assert_nil cash(1875, "Cash App $18.75")
    assert_nil cash(6240, "Groceries $42.40; Cash back $20.00; Debit $62.40")
    assert_nil cash(4000, "Cash $40.00 refunded to card")
    assert_nil cash(4000, "Cash $30.00")
    assert_nil cash(4000, "TOTAL $40.00")
    assert_nil cash(4000, "Cash $40.00", "Cash $30.00; Card $10.00"), "Two readings that disagree are not guessed"
  end

  test "her own words to Mia say cash for one purchase" do
    said = HouseholdFinance::CashPayment.method(:said?)
    assert said.call("I paid $40 cash for lunch at Tasi Demo Cafe")
    assert said.call("Lunch at Tasi Demo Cafe, $40, paid with cash")
    assert said.call("spent $12 at the market in cash")
    assert said.call("used cash for gas $30")
    refute said.call("Lunch at Tasi Demo Cafe $40")
    refute said.call("paid $40 with Cash App at Tasi Demo Cafe")
    refute said.call("Apple Cash purchase $18.75 at Tasi Demo Market")
    refute said.call("got $20 cash back at the market, $62.40 total")
    refute said.call("lunch $40 in cash and gas $30 on my card"), "Two amounts: which one was cash is not guessed"
    refute said.call("took out cash")
  end
end
