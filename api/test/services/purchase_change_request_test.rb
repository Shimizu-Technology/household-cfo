require "test_helper"

class PurchaseChangeRequestTest < ActiveSupport::TestCase
  def parse(message) = HouseholdFinance::PurchaseChangeRequest.parse(message, today: Date.new(2026, 11, 11))

  test "reads an amount correction with the old and new figures" do
    result = parse("the target one yesterday was actually 64 not 46")
    assert_equal [ 6_400, 4_600, false, Date.new(2026, 11, 10) ], [ result.new_cents, result.old_cents, result.void, result.day ]
    range = parse("change the walmart purchase from 30 to 35")
    assert_equal [ 3_500, 3_000 ], [ range.new_cents, range.old_cents ]
    assert_equal 7_000, parse("change the target purchase to $70").new_cents
    natural = parse("the target I bought yesterday cost 64 not 46")
    assert_equal [ 6_400, 4_600 ], [ natural.new_cents, natural.old_cents ]
    assert_equal [ 6_400, 4_600 ], parse("they charged me $64 instead of $46 at target").then { |result| [ result.new_cents, result.old_cents ] }
  end

  test "reads a category move and a removal" do
    assert_equal "groceries", parse("that costco one should be groceries").category_text
    assert_equal "groceries", parse("the costco one should really be under groceries not shopping").category_text
    assert_equal "dining out", parse("move the starbucks charge to dining out").category_text
    removal = parse("delete the 12 dollar starbucks, it was a refund")
    assert removal.void
    assert_equal 1_200, removal.old_cents
    assert parse("the $46 target charge shouldn't be counted").void
  end

  test "leaves new purchase reports and questions alone" do
    [ "I spent 64 at Target yesterday", "Target was 64 yesterday", "how much did I spend at Target", "I paid 64 at Target, should be groceries",
      "what is my budget for groceries" ].each do |message|
      assert_nil parse(message), message
    end
  end

  test "the amount she changes it to is never also the amount that points at the purchase" do
    result = parse("change the target purchase to 70")
    assert_equal [ 7_000, nil ], [ result.new_cents, result.old_cents ]
    assert_equal [ 7_000, nil ], parse("change the target purchase to 70 dollars").then { |parsed| [ parsed.new_cents, parsed.old_cents ] }
    assert_equal [ 7_000, 4_600 ], parse("change the $46 target purchase to 70").then { |parsed| [ parsed.new_cents, parsed.old_cents ] }
    assert_equal [ 1_500, 1_200 ], parse("the 12 dollar starbucks was actually 15").then { |parsed| [ parsed.new_cents, parsed.old_cents ] }
  end

  test "numbers inside a date or time are not money" do
    assert_nil parse("delete the starbucks from nov 9, it was a refund").old_cents
    assert_nil parse("remove the starbucks on 11/9").old_cents
    assert_nil parse("remove the starbucks around 2pm, it was a refund").old_cents
    assert_equal 1_200, parse("remove the 12 dollar starbucks on nov 9").old_cents
  end

  test "a day still ahead stays on the request, so it can never match a confirmed purchase" do
    result = parse("delete the 12 dollar starbucks tomorrow, it was a refund")
    assert_equal Date.new(2026, 11, 12), result.day
    assert_equal Date.new(2026, 11, 10), parse("delete the 12 dollar starbucks yesterday, it was a refund").day
  end
end
