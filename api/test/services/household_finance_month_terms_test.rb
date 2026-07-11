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

  test "budget questions can answer full category breakdowns and largest category" do
    plan = annual_plan_with_breakdown(2026)

    breakdown = HouseholdFinance::BudgetQuestionAnswerer.new(
      "What are all the breakdowns of each category for my budget?",
      annual_plan: plan,
      today: Date.new(2026, 7, 15)
    ).call

    assert_includes breakdown, "Jul 2026"
    assert_includes breakdown, "Fixed essentials $4,000 planned, $125 actual, $3,875 remaining"
    assert_includes breakdown, "Dining Out $300 planned, $40 actual, $260 remaining"
    assert_includes breakdown, "Pending transaction drafts total $7"

    largest = HouseholdFinance::BudgetQuestionAnswerer.new(
      "What's our largest category?",
      annual_plan: plan,
      today: Date.new(2026, 7, 15)
    ).call

    assert_includes largest, "Fixed essentials"
    assert_includes largest, "$4,000 planned"
    assert_includes largest, "I can draft the edit for your approval"

    smallest = HouseholdFinance::BudgetQuestionAnswerer.new(
      "What is the smallest budget category?",
      annual_plan: plan,
      today: Date.new(2026, 7, 15)
    ).call

    assert_includes smallest, "Dining Out"
    assert_includes smallest, "$300 planned"
    refute_includes smallest, "active discretionary plan"
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
    {
      year: year,
      months: months_for(year),
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

  def annual_plan_with_breakdown(year)
    {
      year: year,
      months: months_for(year),
      rows: [
        budget_row(id: 1, name: "Fixed essentials", stack_key: "non_discretionary", stack_label: "Non-discretionary", planned: 4_000, actual: 125),
        budget_row(id: 2, name: "Rent", stack_key: "non_discretionary", stack_label: "Non-discretionary", planned: 1_800, actual: 0),
        budget_row(id: 3, name: "Dining Out", stack_key: "discretionary", stack_label: "Discretionary", planned: 300, actual: 40)
      ],
      monthly_income: months_for(year).index_with { 14_200 }.transform_keys { |month| month.fetch(:id) },
      pending_transaction_drafts: [
        { category_id: 3, amount: 7, occurred_on: Date.new(year, 7, 10).iso8601 }
      ]
    }
  end

  def budget_row(id:, name:, stack_key:, stack_label:, planned:, actual: 0)
    {
      id: id,
      name: name,
      stack_key: stack_key,
      stack_label: stack_label,
      active: true,
      months: (1..12).map { { planned: planned, actual: actual, remaining: planned - actual } }
    }
  end

  def months_for(year)
    (1..12).map do |month|
      starts_on = Date.new(year, month, 1)
      {
        id: month,
        label: starts_on.strftime("%b"),
        starts_on: starts_on.iso8601,
        ends_on: starts_on.end_of_month.iso8601,
        status: "open"
      }
    end
  end
end
