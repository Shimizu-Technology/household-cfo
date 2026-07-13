require "test_helper"

class HouseholdFinanceTransactionDraftBudgetImpactTest < ActiveSupport::TestCase
  test "shows the category result after this draft and other pending activity" do
    plan = annual_plan(
      pending: [
        { id: 8, occurred_on: "2026-07-10", amount: 10, amount_cents: 1_000, category_id: 4, category_name: "Gas", splits: [] },
        { id: 9, occurred_on: "2026-07-11", amount: 200, amount_cents: 20_000, category_id: 4, category_name: "Gas", splits: [] }
      ]
    )
    draft = plan.fetch(:pending_transaction_drafts).last

    impact = HouseholdFinance::TransactionDraftBudgetImpact.new(annual_plan: plan, draft: draft).call.sole

    assert_equal "Gas", impact.fetch(:category_name)
    assert_equal 5_000, impact.fetch(:planned_cents)
    assert_equal 0, impact.fetch(:actual_cents)
    assert_equal 1_000, impact.fetch(:other_pending_cents)
    assert_equal 20_000, impact.fetch(:draft_amount_cents)
    assert_equal 21_000, impact.fetch(:projected_if_approved_cents)
    assert_equal(-16_000, impact.fetch(:remaining_if_approved_cents))
    assert_equal "over", impact.fetch(:status)
  end

  test "keeps split category impacts separate and identifies uncategorized money" do
    plan = annual_plan(pending: [])
    draft = {
      id: 9,
      occurred_on: "2026-07-11",
      amount: 200,
      amount_cents: 20_000,
      splits: [
        { budget_category_id: 4, category_name: "Gas", amount: 120, amount_cents: 12_000 },
        { budget_category_id: nil, category_name: nil, amount: 80, amount_cents: 8_000 }
      ]
    }

    impacts = HouseholdFinance::TransactionDraftBudgetImpact.new(annual_plan: plan, draft: draft).call

    assert_equal 2, impacts.length
    assert_equal(-7_000, impacts.find { |impact| impact[:category_id] == 4 }.fetch(:remaining_if_approved_cents))
    assert_equal "needs_category", impacts.find { |impact| impact[:category_id].nil? }.fetch(:status)
  end

  private

  def annual_plan(pending:)
    {
      year: 2026,
      rows: [
        {
          id: 4,
          name: "Gas",
          months: Array.new(12) { |index| { planned: index == 6 ? 50 : 0, actual: 0, remaining: index == 6 ? 50 : 0 } }
        }
      ],
      pending_transaction_drafts: pending
    }
  end
end
