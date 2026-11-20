require "test_helper"

# Invented receipt text only. Decision 4: buying a gift card is spending;
# paying with one later is not new money.
class HouseholdFinanceReceiptTendersTest < ActiveSupport::TestCase
  def read(total_cents, *texts)
    HouseholdFinance::ReceiptTenders.read(total_cents: total_cents, texts: texts)
  end

  test "receipt lines: a voucher or gift card plus a debit card" do
    reading = read(18_488, "Home fan 129.99; Shelf kit 54.89; Subtotal $184.88; Tax $0.00; TOTAL $184.88; Voucher / gift card $150.00; Debit card 7302 $34.88; Balance due $0.00")

    assert_equal 3_488, reading.new_money_cents
    assert_equal 15_000, reading.not_new_money_cents
    assert_equal [ [ "voucher_or_gift_card", 15_000, false ], [ "card", 3_488, true ] ],
      reading.paid_with.map { |tender| tender.values_at("kind", "amount_cents", "new_money") }
    assert_equal "Debit card 7302", reading.paid_with.last["label"]
  end

  test "sentences: amount first, joined by plus or and" do
    assert_equal 3_488, read(18_488, "Paid with $150.00 voucher/gift card plus $34.88 on debit card 7302.").new_money_cents
    assert_equal 3_488, read(18_488, "Receipt from a store, total $184.88. Paid with a $150.00 voucher/gift card and $34.88 on debit card 7302.").new_money_cents
  end

  test "card ending, Apple Pay and cash are new money; store credit and rewards are not" do
    assert_equal 2_500, read(4_500, "Store credit $20.00; Card ending 1234 $25.00").new_money_cents
    assert_equal 900, read(1_400, "Reward certificate $5.00; Apple Pay $9.00").new_money_cents
    assert_equal 1_000, read(3_000, "Loyalty points $20.00; Cash $10.00").new_money_cents
    assert_equal 1_500, read(2_000, "Store card balance $5.00; Visa xxxx4821 $15.00").new_money_cents
  end

  test "cash handed over less change due" do
    reading = read(18_488, "TOTAL $184.88; Gift card $150.00; Cash $40.00; Change due $5.12")

    assert_equal 3_488, reading.new_money_cents
    assert_equal 3_488, reading.paid_with.find { |tender| tender["kind"] == "cash" }["amount_cents"]
  end

  test "within a cent still reconciles" do
    assert_equal 3_488, read(18_488, "Gift card $150.00; Debit $34.87").new_money_cents
  end

  test "buying a gift card is spending and is never subtracted" do
    assert_nil read(5_000, "Gift card purchase $50.00; Visa $50.00")
    assert_nil read(5_000, "Gift card activation $50.00; Card ending 1234 $50.00")
    assert_nil read(7_500, "Shirt $25.00; Gift card reload $50.00; TOTAL $75.00; Debit card 7302 $75.00")
  end

  test "a gift card balance left over is not a payment" do
    reading = read(18_488, "Gift card $150.00; Debit card 7302 $34.88; Gift card balance remaining $25.00")

    assert_equal 3_488, reading.new_money_cents
    assert_equal 2, reading.paid_with.length
  end

  test "refunds to a gift card or store credit leave the receipt alone" do
    assert_nil read(2_000, "Refund to gift card $20.00; Debit card 7302 $0.00")
    assert_nil read(18_488, "Gift card $150.00; Debit card 7302 $34.88", "Returned $10.00 to store credit")
  end

  test "payments that do not add up to the total leave the receipt alone" do
    assert_nil read(18_488, "Gift card $150.00; Debit card 7302 $30.00")
    assert_nil read(18_488, "Gift card $150.00")
    assert_nil read(18_488, "Gift card $200.00; Debit card 7302 $34.88")
    assert_nil read(18_488, "Gift card $150.00; EBT $34.88")
  end

  test "only new money, or no payment lines, leaves the receipt alone" do
    assert_nil read(18_488, "TOTAL $184.88; Debit card 7302 $184.88")
    assert_nil read(18_488, "Home fan 129.99; Shelf kit 54.89; TOTAL $184.88")
    assert_nil read(18_488, "Card ending 1234")
  end

  test "cash back is a withdrawal, so leave the receipt alone" do
    assert_nil read(5_000, "Gift card $20.00; Debit card 7302 $50.00; Cash back $20.00")
  end

  test "cash back in any text on the receipt leaves it alone" do
    assert_nil read(5_000, "Gift card $20.00; Debit $30.00", "Gift card $20.00; Debit $40.00; Cash back $10.00")
    assert_nil read(5_000, "Gift card $20.00; Debit $30.00", "Customer asked for cashback.")
    assert_equal 3_000, read(5_000, "Gift card $20.00; Debit $30.00", "Paid with a gift card and a debit card.").new_money_cents
    long = "Gift card $20.00; Debit $30.00; #{'Item 1.00; ' * 120}Cash back $10.00"
    assert_operator long.length, :>, HouseholdFinance::ReceiptTenders::MAX_TEXT
    assert_nil read(5_000, long), "Cash back past the part the payment lines are read from still counts"
    assert_nil read(5_000, "Gift card $20.00; Debit $30.00", "#{'x' * 1_200} refunded to gift card")
  end

  test "a minus or bracketed tender amount leaves the receipt alone" do
    assert_nil read(5_000, "Gift card -$20.00; Debit $30.00")
    assert_nil read(5_000, "Gift card ($20.00); Debit $30.00")
    assert_nil read(5_000, "Gift card -20.00; Debit 30.00")
    assert_equal 3_000, read(5_000, "Gift card $20.00; Debit $30.00").new_money_cents
    assert_equal 3_000, read(5_000, "Gift card - $20.00; Debit - $30.00").new_money_cents, "A spaced dash is a separator, not a sign"
  end

  test "edited splits are never replaced by the receipt's snapshot" do
    split = Struct.new(:id, :amount_cents, :metadata)
    intact = [ split.new(1, 2_093, { "receipt_amount_cents" => 11_093, "new_money_amount_cents" => 2_093 }), split.new(2, 1_395, { "receipt_amount_cents" => 7_395, "new_money_amount_cents" => 1_395 }) ]
    assert_equal [ 110.93, 73.95 ], HouseholdFinance::ReceiptTenders.split_amounts(intact, "receipt_amount_cents", 18_488).pluck(:amount)
    edited = [ split.new(1, 3_000, intact[0].metadata), split.new(2, 488, intact[1].metadata) ]
    assert_nil HouseholdFinance::ReceiptTenders.split_amounts(edited, "receipt_amount_cents", 18_488)
    assert_nil HouseholdFinance::ReceiptTenders.split_amounts(edited, "new_money_amount_cents", 3_488)
  end

  test "change without cash handed over leaves the receipt alone" do
    assert_nil read(18_488, "Gift card $150.00; Debit card 7302 $40.00; Change due $5.12")
  end

  test "two places on the receipt that disagree leave it alone" do
    assert_nil read(18_488, "Gift card $150.00; Debit card 7302 $34.88", "Paid with $100.00 gift card plus $84.88 on debit card 7302.")
  end

  test "a reading that agrees in two places is used once" do
    reading = read(18_488, "Voucher / gift card $150.00; Debit card 7302 $34.88", "Paid with $150.00 voucher/gift card plus $34.88 on debit card 7302.")

    assert_equal 3_488, reading.new_money_cents
  end

  test "paid entirely with a gift card is no new money" do
    reading = read(4_000, "TOTAL $40.00; Gift card $40.00; Balance due $0.00")

    assert_equal 0, reading.new_money_cents
  end

  test "thousands separators" do
    assert_equal 23_456, read(123_456, "Gift card $1,000.00; Credit card $234.56").new_money_cents
  end
end
