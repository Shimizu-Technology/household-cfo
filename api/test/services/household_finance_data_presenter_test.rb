require "test_helper"

class HouseholdFinanceDataPresenterTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "blank workspace does not invent debt or CFO filter amounts" do
    household, user = create_household

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
    debt_milestone = debt_milestone(payload)
    decisions = decision_map(payload)

    assert_equal 0, debt_milestone.fetch(:current)
    assert_equal 0, debt_milestone.fetch(:target)
    assert_equal "Add debt balances to track payoff", debt_milestone.fetch(:unit)
    assert_equal "status", debt_milestone.fetch(:kind)
    assert_equal "yellow", debt_milestone.fetch(:status)
    assert_equal [ 0, 0, 0 ], decisions.values.map { |decision| decision.fetch(:amount) }
    assert_equal [ "Wait", "Wait", "Wait" ], decisions.values.map { |decision| decision.fetch(:recommendation) }
    assert_equal false, payload.dig(:dashboard, :readiness_path, :yellow, :reached)
    assert_equal false, payload.dig(:dashboard, :readiness_path, :green, :reached)
  end

  test "debt free household with real inputs keeps debt milestone green" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 250_000, cadence: "monthly")

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

    assert_equal 0, debt_milestone(payload).fetch(:current)
    assert_equal 0, debt_milestone(payload).fetch(:target)
    assert_equal "Debt free", debt_milestone(payload).fetch(:unit)
    assert_equal "status", debt_milestone(payload).fetch(:kind)
    assert_equal "green", debt_milestone(payload).fetch(:status)
  end

  test "debt milestone reports the known remaining balance without inventing payoff progress" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 540_000, minimum_payment_cents: 20_000)

    milestone = debt_milestone(HouseholdFinance::DataPresenter.new(household, user: user).app_data)

    assert_equal 5_400, milestone.fetch(:current)
    assert_equal 0, milestone.fetch(:target)
    assert_equal "dollars", milestone.fetch(:unit)
    assert_equal "debt_remaining", milestone.fetch(:kind)
    assert_equal "yellow", milestone.fetch(:status)
  end

  test "optionality uses approved readiness language instead of conflicting numeric scores" do
    household, user = create_household
    household.update!(primary_goal: "Leave my job safely")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    account = household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 150_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    choices = HouseholdFinance::DataPresenter.new(household, user: user).optionality.fetch(:choices).index_by { |choice| choice.fetch(:label) }

    assert_equal [ "Best fit now", "green" ], choices.fetch("Stay the course").values_at(:fit_label, :fit_tone)
    assert_equal [ "Build runway first", "red" ], choices.fetch("Hybrid transition").values_at(:fit_label, :fit_tone)
    assert_equal [ "Not ready yet", "red" ], choices.fetch("Leap now").values_at(:fit_label, :fit_tone)
    assert choices.values.none? { |choice| choice.key?(:readiness_score) }

    account.update!(balance_cents: 900_000)
    yellow_choices = HouseholdFinance::DataPresenter.new(household, user: user).optionality.fetch(:choices).index_by { |choice| choice.fetch(:label) }
    assert_equal [ "Plan carefully", "yellow" ], yellow_choices.fetch("Hybrid transition").values_at(:fit_label, :fit_tone)
    assert_equal [ "Not ready yet", "red" ], yellow_choices.fetch("Leap now").values_at(:fit_label, :fit_tone)

    account.update!(balance_cents: 1_800_000)
    green_choices = HouseholdFinance::DataPresenter.new(household, user: user).optionality.fetch(:choices).index_by { |choice| choice.fetch(:label) }
    assert_equal [ "Ready to plan", "green" ], green_choices.fetch("Hybrid transition").values_at(:fit_label, :fit_tone)
    assert_equal [ "Possible with safeguards", "yellow" ], green_choices.fetch("Leap now").values_at(:fit_label, :fit_tone)
  end

  test "optionality does not endorse staying the course when cash flow is negative" do
    household, user = create_household
    household.update!(primary_goal: "Leave my job safely")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 200_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")

    choices = HouseholdFinance::DataPresenter.new(household, user: user).optionality.fetch(:choices).index_by { |choice| choice.fetch(:label) }

    assert_equal [ "Stabilize first", "red" ], choices.fetch("Stay the course").values_at(:fit_label, :fit_tone)
    assert_equal [ "Stabilize first", "red" ], choices.fetch("Hybrid transition").values_at(:fit_label, :fit_tone)
    assert_equal [ "Not ready yet", "red" ], choices.fetch("Leap now").values_at(:fit_label, :fit_tone)
  end

  test "optionality uses a red tone when cash flow is exactly break-even" do
    household, user = create_household
    household.update!(primary_goal: "Leave my job safely")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 300_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 900_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    hybrid = HouseholdFinance::DataPresenter.new(household, user: user).optionality.fetch(:choices).find { |choice| choice.fetch(:label) == "Hybrid transition" }

    assert_equal [ "Stabilize first", "red" ], hybrid.values_at(:fit_label, :fit_tone)
  end

  test "optionality follows a non-business household goal without founder transition language" do
    household, user = create_household
    household.update!(primary_goal: "Build a three-month emergency fund without falling behind on bills")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.income_sources.create!(label: "Side business", source_type: "business", amount_cents: 50_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 370_000, cadence: "monthly")
    household.goals.create!(label: household.primary_goal, goal_type: "transition", priority: 2)

    payload = HouseholdFinance::DataPresenter.new(household, user: user).optionality

    assert_equal household.primary_goal, payload.fetch(:scenario)
    assert_equal [ "Monthly surplus", "Target runway reserve", "Runway gap" ], payload.fetch(:levers).pluck(:label)
    assert_equal [ "Protect the baseline", "Build the goal fund", "Accelerate the goal" ], payload.fetch(:choices).pluck(:label)
    refute_includes payload.to_json, "Business needs to pay"
    refute_includes payload.to_json, "Hybrid transition"
    refute_includes payload.to_json, "Leap now"
  end

  test "founder transition counts only recurring income that continues after leaving a job" do
    travel_to Date.new(2026, 8, 24) do
      household, user = create_household
      household.update!(primary_goal: "Leave my job and run the business full-time")
      household.income_sources.create!(label: "Departing salary", source_type: "job", amount_cents: 545_000, cadence: "monthly")
      rental = household.income_sources.create!(label: "Rental property", source_type: "rental", amount_cents: 140_000, cadence: "monthly")
      rental.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 145_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      household.income_sources.create!(label: "Royalties", source_type: "passive", amount_cents: 40_000, cadence: "monthly")
      household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 120_000, cadence: "monthly")
      household.income_sources.create!(label: "Old rental", source_type: "rental", amount_cents: 500_000, cadence: "monthly", active: false)
      household.expense_items.create!(label: "Monthly categories", stack_key: "non_discretionary", amount_cents: 692_500, cadence: "monthly")
      household.debts.create!(label: "Credit card", debt_type: "credit_card", balance_cents: 735_000, minimum_payment_cents: 92_000)

      optionality = HouseholdFinance::DataPresenter.new(household, user: user).optionality
      levers = optionality.fetch(:levers).index_by { |lever| lever.fetch(:label) }
      business_target = HouseholdFinance::DataPresenter.new(household, user: user).cfo_filter.fetch(:targets)
        .find { |target| target.fetch(:label) == "Monthly business revenue" }

      assert_equal 1_850, levers.fetch("Income continuing after transition").fetch(:amount)
      assert_equal 5_995, levers.fetch("Business needs to pay").fetch(:amount)
      assert_equal 1_200, levers.fetch("Current business income").fetch(:amount)
      assert_equal 4_795, optionality.fetch(:monthly_gap)
      assert_equal 5_995, business_target.fetch(:target)
    end
  end

  test "current recurring income changes reconcile across dashboard profile and optionality" do
    travel_to Date.new(2026, 8, 24) do
      household, user = create_household
      household.update!(primary_goal: "Leave my job safely")
      job = household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
      business = household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 100_000, cadence: "monthly")
      job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 700_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      business.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 200_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      job.income_schedule_entries.create!(entry_type: "one_time", label: "Bonus", amount_cents: 500_000, cadence: "one_time", effective_on: Date.new(2026, 8, 15))
      household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 750_000, cadence: "monthly")

      payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
      levers = payload.dig(:optionality, :levers).index_by { |lever| lever.fetch(:label) }
      income_items = payload.dig(:profile, :sections).find { |section| section.fetch(:label) == "Income" }.fetch(:items).index_by { |item| item.fetch(:label) }

      assert_equal 9_000, payload.dig(:dashboard, :summary, :monthly_income)
      assert_equal 0, levers.fetch("Income continuing after transition").fetch(:amount)
      assert_equal 7_500, levers.fetch("Business needs to pay").fetch(:amount)
      assert_equal 2_000, levers.fetch("Current business income").fetch(:amount)
      assert_equal 5_500, payload.dig(:optionality, :monthly_gap)
      assert_equal 7_000, income_items.fetch("Primary income").fetch(:amount)
      assert_equal 2_000, income_items.fetch("Business").fetch(:amount)
      assert_equal 7_000, payload.dig(:workspace, :setup_values, :primary_income)
      assert_equal 2_000, payload.dig(:workspace, :setup_values, :business_income)
    end
  end

  test "reduced-hours transitions retain only an approved effective reduced salary" do
    travel_to Date.new(2026, 8, 24) do
      household, user = create_household
      household.update!(primary_goal: "Reduce my work hours and grow my business")
      job = household.income_sources.create!(label: "Reduced-hours salary", source_type: "job", amount_cents: 600_000, cadence: "monthly")
      job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 350_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      household.income_sources.create!(label: "Unverified second salary", source_type: "job", amount_cents: 200_000, cadence: "monthly")
      future_job = household.income_sources.create!(label: "Future reduced salary", source_type: "job", amount_cents: 400_000, cadence: "monthly")
      future_job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 250_000, cadence: "monthly", effective_on: Date.new(2026, 9, 1))
      raised_job = household.income_sources.create!(label: "Raised salary", source_type: "job", amount_cents: 100_000, cadence: "monthly")
      raised_job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 150_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      household.income_sources.create!(label: "Rental", source_type: "rental", amount_cents: 100_000, cadence: "monthly")
      household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 75_000, cadence: "monthly")
      household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 700_000, cadence: "monthly")

      payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
      levers = payload.dig(:optionality, :levers).index_by { |lever| lever.fetch(:label) }
      business_target = payload.dig(:cfoFilter, :targets).find { |target| target.fetch(:label) == "Monthly business revenue" }

      assert_equal 4_500, levers.fetch("Income continuing after transition").fetch(:amount)
      assert_equal 2_500, levers.fetch("Business needs to pay").fetch(:amount)
      assert_equal 1_750, payload.dig(:optionality, :monthly_gap)
      assert_equal 2_500, business_target.fetch(:target)
    end
  end

  test "irregular expense cadences reconcile across profile setup dashboard and the current budget month" do
    travel_to Date.new(2026, 1, 15) do
      household, user = create_household
      household.expense_items.create!(label: "Weekly groceries", stack_key: "discretionary", amount_cents: 100, cadence: "weekly")
      household.expense_items.create!(label: "Annual registration", stack_key: "sinking_expected", amount_cents: 10_000, cadence: "annual")

      payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
      expense_items = payload.dig(:profile, :sections).find { |section| section.fetch(:label) == "Expenses" }.fetch(:items).index_by { |item| item.fetch(:label) }
      budget_rows = payload.dig(:budget, :annual_plan, :rows).index_by { |row| row.fetch(:name) }

      assert_equal 4.34, expense_items.fetch("Weekly groceries").fetch(:amount)
      assert_equal 4.34, payload.dig(:workspace, :setup_values, :flexible_spend)
      assert_equal 4.34, payload.dig(:dashboard, :summary, :flexible_spend)
      assert_equal 4.34, budget_rows.fetch("Weekly groceries").fetch(:months).first.fetch(:planned)
      assert_equal 8.34, expense_items.fetch("Annual registration").fetch(:amount)
      assert_equal 8.34, payload.dig(:workspace, :setup_values, :expected_sinking_fund)
      assert_equal 8.34, budget_rows.fetch("Annual registration").fetch(:months).first.fetch(:planned)
    end
  end

  test "saving unchanged current-month expense totals preserves their original irregular cadence" do
    travel_to Date.new(2026, 1, 15) do
      household, user = create_household
      expense = household.expense_items.create!(label: "Weekly groceries", stack_key: "discretionary", amount_cents: 100, cadence: "weekly")
      setup_values = HouseholdFinance::DataPresenter.new(household, user: user).workspace.fetch(:setup_values)

      HouseholdFinance::SetupUpdater.new(household, flexible_spend: setup_values.fetch(:flexible_spend)).call

      assert_equal 100, expense.reload.amount_cents
      assert_equal "weekly", expense.cadence
    end
  end

  test "deficit household does not show a negative non-essential purchase amount" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 200_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 250_000, cadence: "monthly")

    decisions = decision_map(HouseholdFinance::DataPresenter.new(household, user: user).app_data)

    assert_equal 0, decisions.fetch("Non-essential purchase").fetch(:amount)
    assert_equal "Wait", decisions.fetch("Non-essential purchase").fetch(:recommendation)
  end

  test "extra debt recommendation never exceeds the safe monthly decision amount" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 710_000, cadence: "monthly")
    household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 690_000, cadence: "monthly")
    household.debts.create!(label: "Visa", debt_type: "credit_card", balance_cents: 100_000, minimum_payment_cents: 10_000)
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 4_200_000)

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
    decision = decision_map(payload).fetch("Extra debt payment")

    assert_equal 40, payload.dig(:dashboard, :summary, :next_safe_to_spend_amount)
    assert_equal 40, decision.fetch(:amount)
    assert_equal "Approve", decision.fetch(:recommendation)
  end

  test "surplus capacity metrics are named and calculated as scenarios instead of savings contributions" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 350_000, cadence: "monthly")
    household.accounts.create!(label: "Retirement", account_type: "retirement", balance_cents: 1_000_000)

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

    assert_equal 30, payload.dig(:dashboard, :summary, :monthly_surplus_rate_percent)
    refute payload.dig(:dashboard, :summary).key?(:savings_rate_percent)
    assert_equal 1_500, payload.dig(:wealth, :summary, :monthly_surplus_available)
    assert_equal 180_000, payload.dig(:wealth, :summary, :ten_year_surplus_capacity)
    refute payload.dig(:wealth, :summary).key?(:monthly_wealth_building)
    refute payload.dig(:wealth, :summary).key?(:retirement_projection)
  end

  test "runway transfer is optional after runway target is met" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_800_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    decisions = decision_map(HouseholdFinance::DataPresenter.new(household, user: user).app_data)

    assert_equal "Optional", decisions.fetch("Runway transfer").fetch(:recommendation)
  end

  test "dashboard and Mia prompts use one approved readiness status" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 150_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

    assert_equal "red", payload.dig(:dashboard, :summary, :readiness_tone)
    assert_equal 0, payload.dig(:dashboard, :summary, :next_safe_to_spend_amount)
    assert_equal "Protect the baseline and build runway.", payload.dig(:dashboard, :coach_read, :title)
    assert_equal 3.0, payload.dig(:dashboard, :readiness_path, :yellow, :runway_months)
    assert_equal 9_000, payload.dig(:dashboard, :readiness_path, :yellow, :protected_liquid_target)
    assert_equal 7_500, payload.dig(:dashboard, :readiness_path, :yellow, :protected_liquid_gap)
    assert_equal false, payload.dig(:dashboard, :readiness_path, :yellow, :reached)
    assert_equal 6.0, payload.dig(:dashboard, :readiness_path, :green, :runway_months)
    assert_equal 18_000, payload.dig(:dashboard, :readiness_path, :green, :protected_liquid_target)
    assert_equal 16_500, payload.dig(:dashboard, :readiness_path, :green, :protected_liquid_gap)
    assert_includes payload.dig(:dashboard, :next_steps), "Pause new wants and direct available surplus to essential bills, expected expenses, and runway until the household reaches Yellow."
    assert_includes payload.dig(:mia, :quick_prompts), "Why is my readiness Red?"
    refute_includes payload.dig(:mia, :quick_prompts), "Why is my baseline yellow?"
    assert_equal "Wait", decision_map(payload).fetch("Extra debt payment").fetch(:recommendation)
    assert_equal 0, decision_map(payload).fetch("Extra debt payment").fetch(:amount)
  end

  test "readiness path marks Yellow and Green thresholds from the saved runway target" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    account = household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 900_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)

    yellow_path = HouseholdFinance::DataPresenter.new(household, user: user).dashboard.fetch(:readiness_path)

    assert_equal true, yellow_path.dig(:yellow, :reached)
    assert_equal false, yellow_path.dig(:green, :reached)
    assert_equal 0, yellow_path.dig(:yellow, :protected_liquid_gap)
    assert_equal 9_000, yellow_path.dig(:green, :protected_liquid_gap)

    account.update!(balance_cents: 1_800_000)
    green_path = HouseholdFinance::DataPresenter.new(household, user: user).dashboard.fetch(:readiness_path)

    assert_equal true, green_path.dig(:yellow, :reached)
    assert_equal true, green_path.dig(:green, :reached)
    assert_equal 0, green_path.dig(:green, :protected_liquid_gap)
  end

  test "action center counts transaction and Mia reviews separately" do
    household, user = create_household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: Date.current.year)
    category = manager.create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 100)
    household.transaction_drafts.create!(
      budget_category: category,
      merchant: "Cafe",
      occurred_on: Date.current,
      total_amount_cents: 1_200,
      source_type: "manual_chat",
      status: "pending"
    )
    household.transaction_drafts.create!(
      budget_category: category,
      merchant: "Historical cafe",
      occurred_on: Date.current.prev_year,
      total_amount_cents: 900,
      source_type: "plaid",
      status: "pending"
    )
    household.mia_action_drafts.create!(
      requested_by_user: user,
      year: Date.current.year,
      draft_type: "budget_edit",
      status: "pending",
      title: "Review budget",
      summary: "Review a planned change"
    )
    household.mia_action_drafts.create!(
      requested_by_user: user,
      year: Date.current.prev_year.year,
      draft_type: "budget_edit",
      status: "pending",
      title: "Historical budget review",
      summary: "Review an older planned change"
    )

    action_center = HouseholdFinance::DataPresenter.new(household, user: user).dashboard.fetch(:action_center)

    assert_equal 1, action_center.fetch(:transaction_review_count)
    assert_equal 1, action_center.fetch(:mia_action_review_count)
    assert_equal 2, action_center.fetch(:total_review_count)
    assert_equal Date.current.month - 1, action_center.fetch(:current_month_index)
  end

  private

  def create_household
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(
      created_by_user: user,
      name: "Test household",
      primary_goal: "Build a clear monthly money rhythm."
    )
    household.household_memberships.create!(user: user, role: "owner")

    [ household, user ]
  end

  def debt_milestone(payload)
    payload.dig(:wealth, :milestones).find { |milestone| milestone.fetch(:label) == "Debt payoff" }
  end

  def decision_map(payload)
    payload.dig(:cfoFilter, :decisions).index_by { |decision| decision.fetch(:item) }
  end
end
