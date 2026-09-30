require "test_helper"

class HouseholdFinanceMiaHypotheticalScenarioAnswererTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: "scenario-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: user, name: "Scenario household", primary_goal: "Build runway")
    @household.income_sources.create!(label: "Income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    @household.expense_items.create!(label: "Essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    @household.debts.create!(label: "Card", debt_type: "credit_card", balance_cents: 200_000, minimum_payment_cents: 20_000)
    @household.goals.create!(label: "Runway", goal_type: "runway", target_months: 6, priority: 1)
    @household.update!(confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household)
    @manager.plan_data
  end

  test "bonus stays one-time and does not change recurring readiness" do
    before = HouseholdFinance::SnapshotBuilder.new(@household, annual_budget_manager: @manager).call
    result = answer("one_time_income", 1_000, "Bonus")
    after = HouseholdFinance::SnapshotBuilder.new(@household.reload, annual_budget_manager: @manager).call

    assert_equal before, after
    assert_includes result.body, "not saved or approved income"
    assert_includes result.body, "recurring monthly income remains $5,000"
  end

  test "medical bill requires a funding account before claiming runway impact" do
    result = answer("essential_expense", 1_200, "Medical bill")

    assert_includes result.body, "not a saved bill"
    assert_includes result.body, "cannot calculate an exact runway or account impact"
    assert_includes result.body, "funding account"
  end

  test "extra debt payment does not change the saved debt" do
    assert_no_changes(-> { @household.debts.sum(:balance_cents) }) do
      result = answer("extra_debt_payment", 500, "Extra card payment")
      assert_includes result.body, "not scheduled, paid, or deducted"
    end
  end

  test "unresolved timing is declined instead of using the selected month" do
    result = HouseholdFinance::MiaHypotheticalScenarioAnswerer.new(
      @household,
      scenario_type: "one_time_income",
      amount: 1_000,
      label: "Bonus",
      timing_unavailable: true,
      annual_budget_manager: @manager,
      reference_month: 1
    ).call

    assert_includes result.body, "could not ground the requested timing"
    assert_includes result.body, "did not apply the selected budget month"
    assert_includes result.body, "was not saved"
  end

  private

  def answer(type, dollars, label)
    HouseholdFinance::MiaHypotheticalScenarioAnswerer.new(
      @household,
      scenario_type: type,
      amount: dollars,
      label: label,
      annual_budget_manager: @manager,
      reference_month: Date.current.month
    ).call
  end
end
