require "test_helper"

class HouseholdFinanceMonthTermsTest < ActiveSupport::TestCase
  test "month terms share one based numbers and zero based UI indexes" do
    assert_equal 7, HouseholdFinance::MonthTerms.number("jul")
    assert_equal 6, HouseholdFinance::MonthTerms.index("jul")

    report_range = HouseholdFinance::SpendingReportQuery.new("How was my spending for July?", today: Date.new(2026, 1, 15)).range
    assert_equal Date.new(2026, 7, 1), report_range.fetch(:start_on)
    assert_equal Date.new(2026, 7, 31), report_range.fetch(:end_on)

    months = (1..12).map do |month|
      starts_on = Date.new(2026, month, 1)
      {
        id: month,
        label: starts_on.strftime("%b"),
        starts_on: starts_on.iso8601,
        ends_on: starts_on.end_of_month.iso8601,
        status: "open"
      }
    end
    plan = {
      year: 2026,
      months: months,
      rows: [
        {
          id: 1,
          name: "Dining Out",
          stack_key: "discretionary",
          stack_label: "Discretionary",
          active: true,
          months: (1..12).map do |month|
            { planned: month * 10, actual: 0, remaining: month * 10 }
          end
        }
      ],
      pending_transaction_drafts: []
    }

    answer = HouseholdFinance::BudgetQuestionAnswerer.new("How much is set aside for July food?", annual_plan: plan, today: Date.new(2026, 1, 15)).call
    assert_includes answer, "Jul 2026"
    assert_includes answer, "Dining Out $70 planned"
  end
end
