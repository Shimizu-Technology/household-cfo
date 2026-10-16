require "test_helper"

# QA F7: spending follow-ups must answer the category or merchant asked about,
# and the same month must not produce two different under-plan numbers.
class HouseholdFinanceSpendingReportFocusTest < ActiveSupport::TestCase
  test "a named category gets a focused answer" do
    answer = narrate("and dining out?")

    assert_includes answer, "Dining out has $91.95 in confirmed spending against $200 planned, $108.05 under plan."
    assert_includes answer, "The largest confirmed charge there was Capricciosa $64.20 Oct 12."
    refute_includes answer, "Top actual categories"
  end

  test "a named merchant gets its own total and share" do
    answer = narrate("how much of that was jollibee")

    assert_includes answer, "confirmed spending at Jollibee is $27.75 across 1 transaction: Jollibee $27.75 Oct 3."
    refute_includes answer, "Top actual categories"
  end

  test "merchant matching ignores apostrophes and includes pending drafts separately" do
    answer = narrate("what about mcdonalds", pending: [ { merchant: "McDonald's", amount: 12.0, occurred_on: "2026-10-15" } ])

    assert_includes answer, "there is no confirmed spending at McDonald's"
    assert_includes answer, "Pending drafts at McDonald's total $12"
  end

  test "an unscoped question keeps the full report without bank wording when no bank is synced" do
    answer = narrate("how much did we spend this month")

    assert_includes answer, "Top actual categories"
    assert_includes answer, "confirmed spending is $595.95 against $1,625.80 planned"
    refute_includes answer, "synced bank activity"
    refute_includes answer, "bank-pending"
  end

  test "bank wording stays when the household has synced bank activity" do
    answer = narrate("how much did we spend this month", bank: { posted_outflow_count: 2, pending_count: 0, inflow_count: 0, inflow: 0.0, top_merchants: [] }, bank_observed: 40.0)

    assert_includes answer, "synced bank activity shows $40 in posted outflows"
    assert_includes answer, "Posted bank activity still needing household review"
  end

  test "the current month by name ends today like this month while past months stay whole" do
    today = Date.new(2026, 10, 16)
    october = HouseholdFinance::SpendingReportQuery.new("how much did we spend in october", today: today).range
    this_month = HouseholdFinance::SpendingReportQuery.new("how much did we spend this month", today: today).range
    september = HouseholdFinance::SpendingReportQuery.new("how much did we spend in september", today: today).range

    assert_equal this_month, october
    assert_equal({ start_on: Date.new(2026, 9, 1), end_on: Date.new(2026, 9, 30) }, september)
  end

  test "a part-month report reads as pace, never as a finished month over plan" do
    report = report(pending: [], bank: nil, bank_observed: 0).merge(start_on: "2026-10-01", end_on: "2026-10-16")
    report[:categories] = [ { id: 3, name: "Dining out", planned: 80.0, actual: 91.95, pending: 0.0 } ]
    report[:totals] = report[:totals].merge(planned: 80.0, actual: 91.95, remaining: -11.95)

    focus = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "and dining out?").call
    refute_match(/\bover plan\b/, focus)
    assert_includes focus, "over the plan so far"
    assert_includes focus, "prorated through Oct 16"

    status = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "are we over budget in october").call
    refute_match(/\bover plan\b/, status)
    assert_includes status, "over the plan so far"
    assert_includes status, "not the full-month plan"

    categories = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "what categories are over plan").call
    assert_includes categories, "over the plan so far"
    assert_includes categories, "prorated through Oct 16"
  end

  test "a whole past month keeps plain plan wording" do
    report = report(pending: [], bank: nil, bank_observed: 0).merge(start_on: "2026-09-01", end_on: "2026-09-30")
    assert_includes HouseholdFinance::SpendingReportNarrator.new(report, prompt: "and dining out?").call, "under plan"
  end

  test "a merchant total from a full 100-transaction window says so and omits the share" do
    report = report(pending: [], bank: nil, bank_observed: 0)
    report[:transactions] = Array.new(HouseholdFinance::SpendingReport::MAX_TRANSACTIONS) do |index|
      { merchant: index.zero? ? "Jollibee" : "Shell", amount: 10.0, occurred_on: "2026-10-03", categories: [] }
    end
    answer = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "how much of that was jollibee").call
    assert_includes answer, "In the most recent 100 transactions"
    refute_includes answer, "% of the"
  end

  private

  def narrate(prompt, pending: [], bank: nil, bank_observed: 0)
    HouseholdFinance::SpendingReportNarrator.new(report(pending: pending, bank: bank, bank_observed: bank_observed), prompt: prompt).call
  end

  def report(pending:, bank:, bank_observed:)
    {
      period_label: "Oct 1, 2026 – Oct 16, 2026",
      plan_available: true,
      totals: { planned: 1_625.8, actual: 595.95, pending: pending.sum { |draft| draft[:amount] }, bank_observed: bank_observed, bank_needs_review: 0, bank_pending: 0, remaining: 1_029.85 },
      bank_activity: bank || { posted_outflow_count: 0, pending_count: 0, inflow_count: 0, inflow: 0.0, top_merchants: [] },
      categories: [
        { id: 1, name: "Fixed essentials", planned: 1_083.87, actual: 248.10, pending: 0.0 },
        { id: 2, name: "Flexible spending", planned: 341.93, actual: 255.90, pending: 0.0 },
        { id: 3, name: "Dining out", planned: 200.0, actual: 91.95, pending: 0.0 }
      ],
      transactions: [
        { merchant: "GPA Power", amount: 248.10, occurred_on: "2026-10-14", categories: [ "Fixed essentials" ] },
        { merchant: "Capricciosa", amount: 64.20, occurred_on: "2026-10-12", categories: [ "Dining out" ] },
        { merchant: "Jollibee", amount: 27.75, occurred_on: "2026-10-03", categories: [ "Dining out" ] }
      ],
      pending_drafts: pending
    }
  end
end
