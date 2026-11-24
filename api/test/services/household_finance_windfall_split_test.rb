# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class HouseholdFinanceWindfallSplitTest < ActiveSupport::TestCase
  include PersonaTestHelper

  ORDER = %w[emergency_fund consumer_debt surplus].freeze

  test "fills each step in the program's order and keeps the rest as surplus" do
    split = split(amount: 600_000, order: ORDER, gap: 530_000, debt: 50_000)
    assert_equal [ [ "emergency_fund", 530_000 ], [ "consumer_debt", 50_000 ], [ "surplus", 20_000 ] ], pairs(split)

    split = split(amount: 600_000, order: %w[consumer_debt emergency_fund surplus], gap: 530_000, debt: 150_000)
    assert_equal [ [ "consumer_debt", 150_000 ], [ "emergency_fund", 450_000 ] ], pairs(split)
  end

  test "an emergency fund gap larger than the windfall takes all of it" do
    assert_equal [ [ "emergency_fund", 100_000 ] ], pairs(split(amount: 100_000, order: ORDER, gap: 530_000, debt: 50_000))
  end

  test "a known $0 gap and $0 consumer debt send the money to surplus" do
    assert_equal [ [ "surplus", 100_000 ] ], pairs(split(amount: 100_000, order: ORDER, gap: 0, debt: 0))
    assert_equal [ [ "emergency_fund", 40_000 ], [ "surplus", 60_000 ] ], pairs(split(amount: 100_000, order: ORDER, gap: 40_000, debt: 0))
  end

  test "an unknown step holds the rest and ends the split, never treated as $0" do
    assert_equal [ { key: "consumer_debt", cents: 100_000, room_known: false } ], split(amount: 100_000, order: %w[consumer_debt emergency_fund surplus], gap: 530_000, debt: nil)
    assert_equal [ { key: "emergency_fund", cents: 40_000, room_known: true }, { key: "consumer_debt", cents: 60_000, room_known: false } ],
      split(amount: 100_000, order: ORDER, gap: 40_000, debt: nil)
  end

  test "the parts add up to the whole amount to the cent" do
    [ [ 123_457, 33_333, 11_111 ], [ 1, 0, 0 ], [ 99_999, 100_000, nil ], [ 50_001, 25_000, 25_000 ] ].each do |amount, gap, debt|
      assert_equal amount, split(amount: amount, order: ORDER, gap: gap, debt: debt).sum { |step| step[:cents] }, [ amount, gap, debt ].inspect
    end
  end

  test "consumer debt leaves out the mortgage" do
    household = household_with_debts
    household.debts.create!(label: "Home loan", debt_type: "mortgage", balance_cents: 30_000_000, minimum_payment_cents: 150_000)
    household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 150_000, minimum_payment_cents: 10_000)
    assert_equal 150_000, consumer_debt(household)

    only_mortgage = household_with_debts
    only_mortgage.debts.create!(label: "Home loan", debt_type: "mortgage", balance_cents: 30_000_000, minimum_payment_cents: 150_000)
    assert_equal 0, consumer_debt(only_mortgage)
  end

  test "an empty debt list or an unknown card balance is unknown, not $0" do
    household = household_with_debts
    assert_nil consumer_debt(household)

    household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 0, balance_known: false, minimum_payment_cents: 10_000)
    assert_nil consumer_debt(household.reload)
  end

  test "the one-total debt summary counts only when it is a confirmed $0, since it may include a mortgage" do
    household = household_with_debts
    profile = household.household_profile
    profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 150_000, debt_summary_balance_known: true)
    assert_nil consumer_debt(household)

    profile.update!(debt_summary_balance_cents: 0, debt_summary_balance_known: false)
    assert_nil consumer_debt(household)

    profile.update!(debt_summary_balance_cents: 0, debt_summary_balance_known: true)
    assert_equal 0, consumer_debt(household)
  end

  test "within consumer debt, known past-due amounts are caught up before extra principal" do
    # A windfall smaller than the arrears goes entirely to the catch-up.
    assert_equal [ [ "consumer_debt_catch_up", 30_000 ] ], pairs(split(amount: 30_000, order: ORDER, gap: 0, debt: 200_000, catch_up: 50_000))
    # Fully funded catch-up: the rest pays principal on what is left of the same balance.
    assert_equal [ [ "consumer_debt_catch_up", 50_000 ], [ "consumer_debt", 150_000 ], [ "surplus", 50_000 ] ],
      pairs(split(amount: 250_000, order: ORDER, gap: 0, debt: 200_000, catch_up: 50_000))
    # The emergency fund gap still comes first under the program's order.
    assert_equal [ [ "emergency_fund", 40_000 ], [ "consumer_debt_catch_up", 50_000 ], [ "consumer_debt", 10_000 ] ],
      pairs(split(amount: 100_000, order: ORDER, gap: 40_000, debt: 200_000, catch_up: 50_000))
  end

  test "known arrears are reported even when the total consumer debt is unknown" do
    assert_equal [ { key: "consumer_debt_catch_up", cents: 50_000, room_known: true }, { key: "consumer_debt", cents: 50_000, room_known: false } ],
      split(amount: 100_000, order: ORDER, gap: 0, debt: nil, catch_up: 50_000)
  end

  test "the catch-up counts cards and loans, never the mortgage, and stops at each balance" do
    household = household_with_debts
    household.debts.create!(label: "Talun home loan", debt_type: "mortgage", balance_cents: 30_000_000, minimum_payment_cents: 150_000, past_due_cents: 300_000)
    household.debts.create!(label: "Talun Visa", debt_type: "credit_card", balance_cents: 15_000, minimum_payment_cents: 2_500, past_due_cents: 20_000)
    household.debts.create!(label: "Clinic plan", debt_type: "medical", balance_cents: 80_000, minimum_payment_cents: 4_000, past_due_cents: 8_000)
    household.debts.create!(label: "Store card", debt_type: "credit_card", balance_cents: 64_000, minimum_payment_cents: 3_500)
    assert_equal 15_000 + 8_000, HouseholdFinance::WindfallSplit.consumer_catch_up_cents(household.reload)
  end

  private

  def split(amount:, order:, gap:, debt:, catch_up: 0)
    HouseholdFinance::WindfallSplit.new(amount_cents: amount, order: order, emergency_fund_gap_cents: gap, consumer_debt_cents: debt, catch_up_cents: catch_up).call
  end

  def pairs(split) = split.map { |step| [ step[:key], step[:cents] ] }

  def consumer_debt(household) = HouseholdFinance::WindfallSplit.consumer_debt_cents(household.reload)

  def household_with_debts
    user = persona_user(role: "participant")
    household = Household.create!(created_by_user: user, name: "Windfall household", primary_goal: "Build the emergency fund")
    household.household_memberships.create!(user: user, role: "owner")
    household.household_profile || household.create_household_profile!
    household
  end
end
