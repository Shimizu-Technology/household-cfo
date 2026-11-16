require "test_helper"

class HouseholdFinanceBeforeDebtAnswerTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    user = User.create!(clerk_id: "f5-money-#{SecureRandom.hex(5)}", email: "f5-money-#{SecureRandom.hex(5)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(user).household
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Fictional household", primary_goal: "Build savings", primary_income: "5200", fixed_expenses: "2050", flexible_spend: "700").call
  end
  teardown { travel_back }

  test "only unknown debt exposes labelled partial values in chat and dashboard" do
    answer = month_answer
    assert_equal "Before debt payments, your plan leaves $2,450 for November 2026: $5,200 in, $2,750 out. This is a plan figure, not a bank balance or permission to spend. Add your monthly debt payments to complete it.", answer.response
    facts = answer.call
    assert_nil facts[:plan_left_cents]
    assert_nil facts[:planned_out_cents]
    assert facts[:before_debt_payments]
    assert_equal 245000, facts[:before_debt_left_cents]
    assert_equal 275000, facts[:before_debt_out_cents]
    assert_equal facts, HouseholdFinance::DataPresenter.new(@household).dashboard[:month_answer]
  end

  test "known payments and deliberately no debts return complete figures" do
    [ [ "350", 210000, 310000 ], [ "0", 245000, 275000 ] ].each do |payment, left, out|
      HouseholdFinance::SetupUpdater.new(@household, debt_payment: payment).call
      facts = month_answer.call
      assert_not facts[:before_debt_payments]
      assert_nil facts[:before_debt_left_cents]
      assert_equal left, facts[:plan_left_cents]
      assert_equal out, facts[:planned_out_cents]
      refute_includes month_answer.response, "Before debt payments"
    end
  end

  test "missing income group or allocation never exposes a partial figure" do
    plan = HouseholdFinance::AnnualBudgetManager.new(@household).plan_data
    missing_allocation = plan.deep_dup
    missing_allocation[:rows].first[:months][10][:allocation_missing] = true
    assert_not HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: missing_allocation).call[:before_debt_payments]
    missing_group = plan.deep_dup
    missing_group[:rows].reject! { |row| row[:stack_key] == "non_discretionary" }
    @household.update!(confirmed_setup_fields: @household.confirmed_setup_fields - [ "fixed_expenses" ])
    assert_not HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: missing_group).call[:before_debt_payments]
    @household.income_sources.destroy_all
    @household.update!(confirmed_setup_fields: @household.confirmed_setup_fields - [ "primary_income" ])
    facts = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan).call
    assert_not facts[:before_debt_payments]
    assert_nil facts[:before_debt_left_cents]
  end

  test "partial answer names its month keeps the review step and describes a shortfall" do
    plan = HouseholdFinance::AnnualBudgetManager.new(@household).plan_data
    plan[:rows].first[:months][10][:planned] = 5000
    plan[:pending_transaction_drafts] = [ { occurred_on: "2026-11-01", amount_cents: 1000 } ]
    answer = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan)
    text = answer.response(next_move: "Check this proposed change.")
    assert_includes text, "is short by $1,850 for November 2026"
    assert_includes text, "not a bank balance"
    assert_includes text, "Check this proposed change; review the 1 purchase"
    refute_includes text, "a month"
  end

  test "a newly created zero category does not supply an unanswered spending group" do
    @household.update!(confirmed_setup_fields: @household.confirmed_setup_fields - [ "flexible_spend" ])
    @household.expense_items.where(stack_key: "discretionary").destroy_all
    @household.budget_categories.where(stack_key: "discretionary").destroy_all
    HouseholdFinance::AnnualBudgetManager.new(@household).create_category!(name: "Not answered", stack_key: "discretionary")
    facts = month_answer.call
    assert_not facts[:before_debt_payments]
    assert_nil facts[:before_debt_left_cents]
  end


  private

  def month_answer
    HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: HouseholdFinance::AnnualBudgetManager.new(@household).plan_data)
  end
end
