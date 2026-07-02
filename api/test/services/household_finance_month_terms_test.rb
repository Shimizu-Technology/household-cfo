require "test_helper"

class HouseholdFinanceMonthTermsTest < ActiveSupport::TestCase
  test "month terms share one based numbers and zero based UI indexes" do
    assert_equal 7, HouseholdFinance::MonthTerms.number("jul")
    assert_equal 6, HouseholdFinance::MonthTerms.index("jul")

    report_range = HouseholdFinance::SpendingReportQuery.new("How was my spending for July?", today: Date.new(2026, 1, 15)).range
    assert_equal Date.new(2026, 7, 1), report_range.fetch(:start_on)
    assert_equal Date.new(2026, 7, 31), report_range.fetch(:end_on)

    year_range = HouseholdFinance::SpendingReportQuery.new("How am I looking this year?", today: Date.new(2026, 7, 15)).range
    assert_equal Date.new(2026, 1, 1), year_range.fetch(:start_on)
    assert_equal Date.new(2026, 7, 15), year_range.fetch(:end_on)

    budget_status_range = HouseholdFinance::SpendingReportQuery.new("Am I staying within my budget?", today: Date.new(2026, 7, 15)).range
    assert_equal Date.new(2026, 7, 1), budget_status_range.fetch(:start_on)
    assert_equal Date.new(2026, 7, 15), budget_status_range.fetch(:end_on)

    answer = HouseholdFinance::BudgetQuestionAnswerer.new("How much is set aside for July food?", annual_plan: annual_plan(2026), today: Date.new(2026, 1, 15)).call
    assert_includes answer, "Jul 2026"
    assert_includes answer, "Dining Out $70 planned"
  end

  test "relative month budget questions do not read the wrong plan year" do
    december_today = Date.new(2026, 12, 15)
    assert_nil HouseholdFinance::BudgetQuestionAnswerer.new("How much is set aside for next month food?", annual_plan: annual_plan(2026), today: december_today).call

    next_year_answer = HouseholdFinance::BudgetQuestionAnswerer.new("How much is set aside for next month food?", annual_plan: annual_plan(2027), today: december_today).call
    assert_includes next_year_answer, "Jan 2027"
    assert_includes next_year_answer, "Dining Out $10 planned"

    january_today = Date.new(2027, 1, 15)
    assert_nil HouseholdFinance::BudgetQuestionAnswerer.new("How much was set aside for last month food?", annual_plan: annual_plan(2027), today: january_today).call
  end

  private

  def annual_plan(year)
    months = (1..12).map do |month|
      starts_on = Date.new(year, month, 1)
      {
        id: month,
        label: starts_on.strftime("%b"),
        starts_on: starts_on.iso8601,
        ends_on: starts_on.end_of_month.iso8601,
        status: "open"
      }
    end
    {
      year: year,
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
  end
end
