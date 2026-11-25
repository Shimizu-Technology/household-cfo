# frozen_string_literal: true

require "test_helper"

class HouseholdFinanceIncomeSplitTest < ActiveSupport::TestCase
  DEFAULT = { "emergency_fund" => 50, "debt" => 25, "surplus" => 25 }.freeze

  test "splits a named monthly amount by the program's percentages" do
    assert_equal [ [ "emergency_fund", 20_000 ], [ "debt", 10_000 ], [ "surplus", 10_000 ] ], split(40_000)
  end

  test "the parts always add up to the amount; rounding's leftover goes to the largest share" do
    assert_equal [ [ "emergency_fund", 20_835 ], [ "debt", 10_416 ], [ "surplus", 10_416 ] ], split(41_667)
    [ 1, 3, 99, 41_667, 123_457 ].each do |cents|
      assert_equal cents, split(cents).sum(&:last), cents
      assert_equal cents, split(cents, { "emergency_fund" => 33, "debt" => 33, "surplus" => 34 }).sum(&:last), cents
    end
  end

  test "a 0% part is left out" do
    assert_equal [ [ "debt", 28_000 ], [ "surplus", 12_000 ] ], split(40_000, { "emergency_fund" => 0, "debt" => 70, "surplus" => 30 })
  end

  private

  def split(cents, percentages = DEFAULT) = HouseholdFinance::IncomeSplit.new(amount_cents: cents, split: percentages).call
end
