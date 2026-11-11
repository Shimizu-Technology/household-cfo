require "test_helper"

class SetupBillBackfillTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "bf_#{SecureRandom.hex(8)}", email: "bf-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  # The shape chat setup left before bills were their own rows: one total row,
  # with the named bills only in the applied card.
  def legacy_household(parts: [ [ "Rent", 165_000 ], [ "Power", 18_000 ], [ "Insurance", 12_000 ] ], saved: 195_000)
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Legacy", primary_goal: "steady", primary_income: "5200",
      fixed_expenses: HouseholdFinance::Money.dollars(saved).to_s, flexible_spend: "600", credit_card_debt: "0", debt_payment: "0").call
    HouseholdFinance::AnnualBudgetManager.new(@household.reload).ensure_plan!
    state = { "fields" => { "fixed_expenses" => { "parts" => parts.map { |label, cents| { "id" => SecureRandom.hex(4), "label" => label, "cents" => cents, "cadence" => "monthly", "counted" => true, "kind" => "part" } } } } }
    @household.mia_action_drafts.create!(requested_by_user: @user, draft_type: "household_setup", status: "applied", year: Date.current.year, title: "Your setup so far", summary: "Your setup so far",
      metadata: { "setup_card" => state }, applied_at: Time.current)
  end

  def month_answer
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload).read_only_plan_data
    HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan).call
  end

  def fixed(results) = results.select { |result| result.field == "fixed_expenses" }.map(&:action)

  def names(stack = "non_discretionary") = @household.budget_categories.active.where(stack_key: stack).order(:id).pluck(:name)

  test "splits a matching breakdown into one row per bill, keeps every figure, and is a no-op the second time" do
    legacy_household
    assert_equal [ "Fixed essentials" ], names
    before = month_answer
    plan_before = HouseholdFinance::AnnualBudgetManager.new(@household).read_only_plan_data[:rows].select { |row| row[:active] }.sum { |row| row[:months].sum { |month| HouseholdFinance::Money.cents(month[:planned]) } }

    results = HouseholdFinance::SetupBillBackfill.new(@household).call
    assert_equal [ :split ], fixed(results)
    assert_equal %w[Rent Power Insurance], names
    after = month_answer
    assert_equal before.slice(:money_in_cents, :planned_out_cents, :plan_left_cents, :category_plan_cents), after.slice(:money_in_cents, :planned_out_cents, :plan_left_cents, :category_plan_cents)
    plan_after = HouseholdFinance::AnnualBudgetManager.new(@household).read_only_plan_data[:rows].select { |row| row[:active] }.sum { |row| row[:months].sum { |month| HouseholdFinance::Money.cents(month[:planned]) } }
    assert_equal plan_before, plan_after, "every month of the Budget keeps its total"
    assert_equal 1950.0, HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f
    assert @household.budget_categories.archived.exists?(name: "Fixed essentials"), "the old row stays for its history"

    again = HouseholdFinance::SetupBillBackfill.new(@household.reload).call
    assert_equal [], again.map(&:action) - [ :skipped ]
    assert_equal %w[Rent Power Insurance], names
    assert_equal after.slice(:planned_out_cents), month_answer.slice(:planned_out_cents)
  end

  test "leaves a household alone when the breakdown no longer matches the saved total" do
    legacy_household(saved: 200_000)
    results = HouseholdFinance::SetupBillBackfill.new(@household).call
    assert_equal [ :skipped ], fixed(results)
    assert_match(/does not match/, results.find { |result| result.field == "fixed_expenses" }.detail)
    assert_equal [ "Fixed essentials" ], names
  end

  test "keeps confirmed actuals readable under the old row" do
    legacy_household
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    period = HouseholdFinance::AnnualBudgetManager.new(@household).current_period_for(Date.current)
    transaction = @household.household_transactions.create!(merchant: "GPA", occurred_on: Date.current, total_amount_cents: 18_000, status: "confirmed", source_type: "manual_ui", budget_period: period)
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 18_000)
    HouseholdFinance::SetupBillBackfill.new(@household).call
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload).plan_data
    old = plan[:rows].find { |row| row[:name] == "Fixed essentials" }
    assert old, "the old row still shows while it has history"
    assert_equal false, old[:active]
    assert_equal 18_000, transaction.reload.transaction_splits.sum(:amount_cents)
  end

  test "a dry run changes nothing" do
    legacy_household
    results = HouseholdFinance::SetupBillBackfill.new(@household, dry_run: true).call
    assert_equal [ :would_split ], fixed(results)
    assert_equal [ "Fixed essentials" ], names
  end

  test "a household set up by form with no breakdown is left alone" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Form", primary_goal: "steady", primary_income: "5200", fixed_expenses: "1950", flexible_spend: "600", credit_card_debt: "0", debt_payment: "0").call
    HouseholdFinance::AnnualBudgetManager.new(@household.reload).ensure_plan!
    assert_equal [ :skipped ], fixed(HouseholdFinance::SetupBillBackfill.new(@household).call)
    assert_equal [ "Fixed essentials" ], names
  end
end
