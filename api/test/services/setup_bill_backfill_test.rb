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

  def pending_allocation_draft
    manager = HouseholdFinance::AnnualBudgetManager.new(@household.reload)
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    result = HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: manager, raw_input: "raise fixed essentials",
      command: { type: "set_allocation", category_id: category.id, category_name: category.name, amount: "2000", months: manager.send(:plan_coverage).month_numbers(manager.year), year: manager.year }).call
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    result.proposal.create_draft!(source_chat_message: session.chat_messages.create!(role: "user", content: "raise it"), assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review"))
  end

  test "a household with a pending review card is skipped, and that card still applies afterwards" do
    legacy_household
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    draft = pending_allocation_draft
    results = HouseholdFinance::SetupBillBackfill.new(@household).call
    assert_equal [ :skipped ], fixed(results)
    assert_match(/review card is waiting/, results.find { |result| result.field == "fixed_expenses" }.detail)
    assert_equal [ "Fixed essentials" ], names
    applied = HouseholdFinance::MiaActionDraftApplier.new(draft.reload, user: @user).call
    assert applied.success?, applied.errors.to_sentence
    assert_equal 200_000, category.budget_allocations.joins(:budget_period).find_by!(budget_periods: { starts_on: Date.current.beginning_of_month }).planned_amount_cents
    assert category.reload.active?
  end

  test "a purchase waiting for review on the old row keeps it unsplit" do
    legacy_household
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    draft = @household.transaction_drafts.create!(merchant: "GPA", occurred_on: Date.current, total_amount_cents: 18_000, status: "pending", source_type: "manual_ui", budget_category: category)
    assert_match(/purchases waiting/, HouseholdFinance::SetupBillBackfill.new(@household).call.find { |result| result.field == "fixed_expenses" }.detail)
    assert_equal [ "Fixed essentials" ], names
  end

  test "a purchase waiting for review with a split on the old row keeps it unsplit" do
    legacy_household
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    draft = @household.transaction_drafts.create!(merchant: "GPA", occurred_on: Date.current, total_amount_cents: 18_000, status: "pending", source_type: "manual_ui")
    draft.transaction_draft_splits.create!(budget_category: category, amount_cents: 18_000)
    assert_match(/purchases waiting/, HouseholdFinance::SetupBillBackfill.new(@household).call.find { |result| result.field == "fixed_expenses" }.detail)
    assert_equal [ "Fixed essentials" ], names
  end

  test "an inactive expense item with a bill's name is reused, not a collision" do
    legacy_household
    @household.expense_items.create!(label: "Rent", stack_key: "non_discretionary", amount_cents: 99_900, cadence: "monthly", active: false)
    assert_equal [ :split ], fixed(HouseholdFinance::SetupBillBackfill.new(@household.reload).call)
    assert_equal %w[Rent Power Insurance], names
    assert_equal [ 165_000 ], @household.expense_items.where(label: "Rent", active: true).pluck(:amount_cents)
    assert_equal 1, @household.expense_items.where(label: "Rent").count
    assert_equal 1950.0, HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f
  end

  test "a bill saved under the same name in another layer leaves the household alone" do
    legacy_household
    @household.expense_items.create!(label: "Rent", stack_key: "discretionary", amount_cents: 5_000, cadence: "monthly", active: true)
    assert_match(/another layer/, HouseholdFinance::SetupBillBackfill.new(@household.reload).call.find { |result| result.field == "fixed_expenses" }.detail)
    assert_equal [ "Fixed essentials" ], names
  end

  test "the split writes an audit record and the new rows carry the current financial generation" do
    legacy_household
    assert_difference -> { @household.household_audit_events.where(event_type: "setup_bills.split").count }, 1 do
      HouseholdFinance::SetupBillBackfill.new(@household).call
    end
    event = @household.household_audit_events.find_by!(event_type: "setup_bills.split")
    assert_equal %w[Rent Power Insurance], event.metadata.fetch("to").map { |bill| bill["name"] }
    assert_equal [ @household.reload.financial_generation ], @household.expense_items.where(active: true, stack_key: "non_discretionary").distinct.pluck(:financial_generation)
    assert_equal [ @household.financial_generation ], @household.budget_categories.where(name: %w[Rent Power Insurance]).distinct.pluck(:financial_generation)
  end

  test "a card applied before the saved total was last written is not trusted" do
    legacy_household
    @household.mia_action_drafts.update_all(applied_at: 2.days.ago)
    results = HouseholdFinance::SetupBillBackfill.new(@household).call
    assert_equal [ :skipped ], fixed(results)
    assert_equal [ "Fixed essentials" ], names
  end

  test "one household that fails is logged and the rest still split" do
    legacy_household
    other_user = User.create!(clerk_id: "bf2_#{SecureRandom.hex(8)}", email: "bf2-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    other = HouseholdFinance::WorkspaceResolver.new(other_user).household
    original = @household
    @household = other
    legacy_household
    @household = original
    broken = HouseholdFinance::AnnualBudgetManager.instance_method(:create_category_inside_household_lock!)
    calls = 0
    HouseholdFinance::AnnualBudgetManager.define_method(:create_category_inside_household_lock!) do |**options|
      raise ActiveRecord::RecordInvalid, BudgetCategory.new if (calls += 1) == 1
      broken.bind_call(self, **options)
    end
    log = StringIO.new
    results = begin
      HouseholdFinance::SetupBillBackfill.call(Household.where(id: [ original.id, other.id ]).order(:id), logger: Logger.new(log))
    ensure
      HouseholdFinance::AnnualBudgetManager.define_method(:create_category_inside_household_lock!, broken)
    end
    assert_equal [ :error ], results.select { |result| result.action == :error }.map(&:action)
    assert_match(/error/, log.string)
    assert_equal [ :split ], results.select { |result| result.field == "fixed_expenses" }.map(&:action)
    failed = Household.find(results.find { |result| result.action == :error }.household_id)
    assert_equal [ "Fixed essentials" ], failed.budget_categories.active.where(stack_key: "non_discretionary").pluck(:name), "a failed household rolls back whole"
  end

  test "a month with a confirmed actual keeps the same plan figures, and the old row isn't counted beside the new ones" do
    legacy_household
    category = @household.budget_categories.find_by!(name: "Fixed essentials")
    manager = HouseholdFinance::AnnualBudgetManager.new(@household)
    period = manager.current_period_for(Date.current)
    transaction = @household.household_transactions.create!(merchant: "GPA", occurred_on: Date.current, total_amount_cents: 18_000, status: "confirmed", source_type: "manual_ui", budget_period: period)
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 18_000)
    before = month_answer
    HouseholdFinance::SetupBillBackfill.new(@household).call
    after = month_answer
    assert_equal before.slice(:money_in_cents, :planned_out_cents, :plan_left_cents, :spent_cents), after.slice(:money_in_cents, :planned_out_cents, :plan_left_cents, :spent_cents)
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload).plan_data
    month = Date.current.month
    active_planned = plan[:rows].select { |row| row[:active] }.sum { |row| HouseholdFinance::Money.cents(row[:months][month - 1][:planned]) }
    assert_equal 195_000 + 60_000, active_planned, "bills 1,950 plus everyday 600; the archived row's history isn't added on top"
  end
end
