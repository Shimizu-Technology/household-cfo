require "test_helper"

class HouseholdFinanceMiaSetupIntakeTest < ActiveSupport::TestCase
  NUMBERS = "We bring home $5,200 each month. Rent is $1,800, utilities $250, groceries $700, and the car loan minimum is $350.".freeze

  test "reviewed setup arithmetic traces each total to its stated category" do
    result = intake(NUMBERS)
    assert result.actionable?
    actions = result.write_plan.fetch(:actions)
    updates = actions.first.dig(:action, :setup_updates)
    assert_equal 5200, updates.fetch(:primary_income).to_f
    assert_equal 2050, updates.fetch(:fixed_expenses).to_f
    assert_equal 700, updates.fetch(:flexible_spend).to_f
    assert_equal "auto_loan", actions.last.dig(:action, :debt_type)
    assert_equal 350, actions.last.dig(:action, :minimum_payment).to_f
    refute actions.last.fetch(:action).key?(:amount), "a minimum never establishes a balance"
    assert_includes NUMBERS, actions.first.fetch(:source_text)
    assert_includes NUMBERS, actions.last.fetch(:source_text)
  end

  test "ambiguous, negative, hypothetical and read-only clauses do not enter the shortcut" do
    [ "Maybe #{NUMBERS}", "What if #{NUMBERS}", "Do not save. #{NUMBERS}", "#{NUMBERS} My income will change next month.",
      NUMBERS.sub("each month", "each week"), NUMBERS.sub("utilities $250", "utilities -$250"),
      NUMBERS.sub("utilities $250", "utilities $250 or utilities $300"), NUMBERS.sub("$1,800", "$18,000,000") ].each do |text|
      assert_nil intake(text), text
    end
  end

  test "setup intake leaves detailed or summary debt changes to the ordinary validated planner" do
    assert_nil intake(NUMBERS, debt_tracking: { mode: "summary" })
    assert_nil intake(NUMBERS, active_debts: [ { id: 1, label: "Car loan" } ])
    assert_nil intake(NUMBERS, setup_status: { complete: true })
  end

  test "a stated rollup can be reviewed on its own without inventing other setup fields" do
    result = intake("Rent is $1,800 and utilities $250.")
    assert result.actionable?
    assert_equal({ fixed_expenses: "2050.0" }, result.action.fetch(:setup_updates))
    result = intake("Groceries $700 each month.")
    assert_equal({ flexible_spend: "700.0" }, result.action.fetch(:setup_updates))
    assert_nil intake("Rent is $1,800."), "one bill does not imply a complete fixed total"
  end

  test "supported goal target stays separate from saved progress and unknown answers" do
    assert_equal 100000, HouseholdFinance::MiaSetupIntake.goal_target("Build a $1,000 emergency cushion")
    assert_nil HouseholdFinance::MiaSetupIntake.goal_target("Maybe build a $1,000 emergency cushion")
    assert_nil HouseholdFinance::MiaSetupIntake.goal_target("Build an emergency cushion")
  end

  private

  def intake(text, **context)
    HouseholdFinance::MiaSetupIntake.new(text, context: { setup_status: { complete: false }, debt_tracking: { mode: "individual" }, active_debts: [] }.merge(context)).call
  end
end
