# frozen_string_literal: true

require "test_helper"

class HouseholdFinanceWindfallSplitTest < ActiveSupport::TestCase
  test "fills each step in the program's order and keeps the rest as surplus" do
    split = split(amount: 600_000, order: %w[emergency_fund consumer_debt surplus], gap: 530_000, debt: 50_000)
    assert_equal [ [ "emergency_fund", 530_000 ], [ "consumer_debt", 50_000 ], [ "surplus", 20_000 ] ], split.map { |step| [ step[:key], step[:cents] ] }

    split = split(amount: 600_000, order: %w[consumer_debt emergency_fund surplus], gap: 530_000, debt: 150_000)
    assert_equal [ [ "consumer_debt", 150_000 ], [ "emergency_fund", 450_000 ] ], split.map { |step| [ step[:key], step[:cents] ] }
  end

  test "an unknown debt balance takes the rest and says so, never treated as $0" do
    split = split(amount: 100_000, order: %w[consumer_debt emergency_fund surplus], gap: 530_000, debt: nil)
    assert_equal [ { key: "consumer_debt", cents: 100_000, room_known: false } ], split
  end

  private

  def split(amount:, order:, gap:, debt:)
    HouseholdFinance::WindfallSplit.new(amount_cents: amount, order: order, emergency_fund_gap_cents: gap, consumer_debt_cents: debt).call
  end
end
