require "test_helper"
require_relative "../support/persona_test_helper"

class HouseholdFinanceDataPresenterTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include PersonaTestHelper

  test "blank workspace does not invent debt or CFO filter amounts" do
    household, user = create_household
    household.household_profile.update!(
      debt_tracking_mode: "individual",
      debt_summary_balance_known: false,
      debt_summary_minimum_payment_known: false
    )

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
    debt_milestone = debt_milestone(payload)
    decisions = decision_map(payload)

    assert_nil debt_milestone
    assert_equal [ 0, 0, 0 ], decisions.values.map { |decision| decision.fetch(:amount) }
    assert_equal [ "Wait", "Wait", "Wait" ], decisions.values.map { |decision| decision.fetch(:recommendation) }
    assert_equal false, payload.dig(:dashboard, :readiness_path, :yellow, :reached)
    assert_equal false, payload.dig(:dashboard, :readiness_path, :green, :reached)
  end

  test "incomplete setup replaces readiness and decision guidance with setup guidance" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.update!(confirmed_setup_fields: %w[household_name primary_goal primary_income])

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

    assert_equal "Finish your starting picture.", payload.dig(:dashboard, :coach_read, :title)
    assert_includes payload.dig(:dashboard, :coach_read, :body), "Fixed essentials and Flexible spending"
    assert_equal [ "Finish your starting picture" ], payload.dig(:dashboard, :alerts).pluck(:title)
    assert payload.dig(:dashboard, :next_steps).all? { |step| step.match?(/setup|missing|confirm/i) }
    assert_equal [ 0, 0, 0 ], decision_map(payload).values.map { |decision| decision.fetch(:amount) }
    assert_equal [ "Wait", "Wait", "Wait" ], decision_map(payload).values.map { |decision| decision.fetch(:recommendation) }
    assert_equal "Help me finish my household setup", payload.dig(:mia, :quick_prompts).first
    refute payload.dig(:mia, :quick_prompts).any? { |prompt| prompt.match?(/readiness|buy|debt first|leave my job/i) }
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
    household.household_profile.update!(debt_tracking_mode: "individual")
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
      household.household_profile.update!(debt_tracking_mode: "individual")
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

  test "approved reduced salary is retained without depending on narrow transition wording" do
    travel_to Date.new(2026, 8, 24) do
      household, user = create_household
      household.update!(primary_goal: "Scale back my shifts while I build the business")
      job = household.income_sources.create!(label: "Reduced-hours salary", source_type: "job", amount_cents: 600_000, cadence: "monthly")
      job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 350_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1), retained_after_transition: true)
      household.income_sources.create!(label: "Unverified second salary", source_type: "job", amount_cents: 200_000, cadence: "monthly")
      future_job = household.income_sources.create!(label: "Future reduced salary", source_type: "job", amount_cents: 400_000, cadence: "monthly")
      future_job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 250_000, cadence: "monthly", effective_on: Date.new(2026, 9, 1), retained_after_transition: true)
      raised_job = household.income_sources.create!(label: "Raised salary", source_type: "job", amount_cents: 100_000, cadence: "monthly")
      raised_job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 150_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1), retained_after_transition: true)
      unconfirmed_job = household.income_sources.create!(label: "Unconfirmed reduced salary", source_type: "job", amount_cents: 300_000, cadence: "monthly")
      unconfirmed_job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 150_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
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

  test "an approved cadence-changing salary reduction stays retained in every calendar month" do
    household, user = create_household
    household.update!(primary_goal: "Reduce my hours while building the business")
    job = household.income_sources.create!(label: "Reduced-hours salary", source_type: "job", amount_cents: 1_000, cadence: "weekly")
    job.income_schedule_entries.create!(
      entry_type: "recurring_change",
      amount_cents: 4_333,
      cadence: "monthly",
      effective_on: Date.new(2026, 1, 1),
      retained_after_transition: true
    )
    household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 10_000, cadence: "monthly")

    [ Date.new(2026, 1, 15), Date.new(2026, 8, 25) ].each do |date|
      travel_to date do
        payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
        levers = payload.dig(:optionality, :levers).index_by { |lever| lever.fetch(:label) }
        business_target = payload.dig(:cfoFilter, :targets).find { |target| target.fetch(:label) == "Monthly business revenue" }

        assert_equal 43.33, levers.fetch("Income continuing after transition").fetch(:amount), date.to_s
        assert_equal 56.67, levers.fetch("Business needs to pay").fetch(:amount), date.to_s
        assert_equal 56.67, business_target.fetch(:target), date.to_s
      end
    end
  end

  test "a full job departure excludes a prior pay reduction from retained income" do
    travel_to Date.new(2026, 8, 24) do
      household, user = create_household
      job = household.income_sources.create!(label: "Departing salary", source_type: "job", amount_cents: 600_000, cadence: "monthly")
      job.income_schedule_entries.create!(entry_type: "recurring_change", amount_cents: 350_000, cadence: "monthly", effective_on: Date.new(2026, 8, 1))
      household.income_sources.create!(label: "Rental", source_type: "rental", amount_cents: 100_000, cadence: "monthly")
      household.income_sources.create!(label: "Business", source_type: "business", amount_cents: 75_000, cadence: "monthly")
      household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 700_000, cadence: "monthly")

      [
        "Move to my business full-time and exit my position",
        "I want to leave my career to start a business",
        "Quit my full-time day job and grow the business",
        "Resign from my current employer to build the business",
        "Stop working for my employer and build the business",
        "Close the chapter on corporate life and launch my business"
      ].each do |goal|
        household.update!(primary_goal: goal)
        payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
        levers = payload.dig(:optionality, :levers).index_by { |lever| lever.fetch(:label) }
        business_target = payload.dig(:cfoFilter, :targets).find { |target| target.fetch(:label) == "Monthly business revenue" }

        assert_equal 1_000, levers.fetch("Income continuing after transition").fetch(:amount), goal
        assert_equal 6_000, levers.fetch("Business needs to pay").fetch(:amount), goal
        assert_equal 5_250, payload.dig(:optionality, :monthly_gap), goal
        assert_equal 6_000, business_target.fetch(:target), goal
      end
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

  test "blank legacy setup debt values remain unknown in presenter output" do
    household, user = create_household

    HouseholdFinance::SetupUpdater.new(household, credit_card_debt: "", debt_payment: nil).call

    profile = household.household_profile.reload
    refute profile.debt_summary_balance_known?
    refute profile.debt_summary_minimum_payment_known?
    setup_values = HouseholdFinance::DataPresenter.new(household.reload, user: user).setup_values
    assert_nil setup_values.fetch(:credit_card_debt)
    assert_nil setup_values.fetch(:debt_payment)
    refute HouseholdFinance::DataPresenter.new(household, user: user).app_data.dig(:dashboard, :summary, :readiness_available)
  end

  test "blank legacy setup debt values leave individual records unchanged" do
    household, = create_household
    household.household_profile.update!(debt_tracking_mode: "individual")
    debt = household.debts.create!(
      label: "Visa", debt_type: "credit_card", balance_cents: 310_000,
      minimum_payment_cents: 17_500, balance_known: true, minimum_payment_known: true
    )

    HouseholdFinance::SetupUpdater.new(household, credit_card_debt: "", debt_payment: nil).call

    assert_equal "individual", household.household_profile.reload.debt_tracking_mode
    assert_equal 310_000, debt.reload.balance_cents
    assert_equal 17_500, debt.minimum_payment_cents
    assert debt.balance_known?
    assert debt.minimum_payment_known?
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
    household.update!(
      primary_goal: "Pay down debt without destabilizing the monthly plan",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s)
    )
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 710_000, cadence: "monthly")
    household.expense_items.create!(label: "Monthly outflow", stack_key: "non_discretionary", amount_cents: 690_000, cadence: "monthly")
    household.expense_items.create!(label: "Flexible spending", stack_key: "discretionary", amount_cents: 0, cadence: "monthly")
    household.household_profile.update!(debt_tracking_mode: "individual")
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
    household.update!(confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))

    decisions = decision_map(HouseholdFinance::DataPresenter.new(household, user: user).app_data)

    assert_equal "Optional", decisions.fetch("Runway transfer").fetch(:recommendation)
  end

  test "dashboard and Mia prompts use one approved readiness status" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 700_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 300_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 150_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6, priority: 1)
    household.update!(confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))

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

  test "missing liquid balances keep runway nullable and point blockers to account controls" do
    household, user = create_household
    household.accounts.delete_all
    household.update!(confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

    assert_nil payload.dig(:dashboard, :summary, :runway_months)
    assert_nil payload.dig(:dashboard, :summary, :next_safe_to_spend_amount)
    assert_equal "Add or update liquid account balances under Accounts & assets first.", payload.dig(:optionality, :question)
    assert_equal "Liquid balances needed", payload.dig(:wealth, :milestones, 0, :label)
    assert_includes payload.dig(:wealth, :milestones, 0, :unit), "Accounts & assets"
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

  test "action center counts a year-independent action plan from another year" do
    household, user = create_household
    draft = household.mia_action_drafts.create!(
      requested_by_user: user, year: Date.current.prev_year.year, draft_type: "action_plan", status: "pending",
      title: "Update a savings goal", summary: "Review the saved goal change"
    )
    draft.mia_action_items.create!(
      position: 0, action_type: "update_goal", operation_key: "goal.record.update", operation_version: 1,
      prepared_operation: { "operation_key" => "goal.record.update" }, prepared_operation_fingerprint: "goal-plan",
      label: "Update goal", payload: {}, before_snapshot: {}, after_snapshot: {}
    )

    action_center = HouseholdFinance::DataPresenter.new(household, user: user).dashboard.fetch(:action_center)

    assert_equal 1, action_center.fetch(:mia_action_review_count)
    assert_equal 1, action_center.fetch(:total_review_count)
  end

  test "chat history preloads citation provenance with a bounded query count" do
    household, user = create_household
    coach = persona_user(email: "history-citation-coach@example.com")
    item = approved_content_item(owner: coach, title: "History context", content: "Keep the next step clear.")
    pack = published_content_pack(owner: coach, items: [ item ])
    session = household.chat_sessions.create!(user: user, title: "Ask Mia")
    create_cited_message = lambda do |index|
      message = session.chat_messages.create!(role: "assistant", content: "Answer #{index}")
      message.coach_content_citations.create!(
        coach_content_item_version: item.current_approved_version,
        coach_content_pack_version: pack.current_published_version,
        rank: 1,
        reason: "Context supplied for: next step"
      )
    end

    create_cited_message.call(1)
    first_count = citation_query_count do
      @first_page = HouseholdFinance::DataPresenter.new(household, user: user).send(:chat_message_page, before_id: nil, limit: 60)
    end

    5.times { |index| create_cited_message.call(index + 2) }
    expanded_count = citation_query_count do
      @expanded_page = HouseholdFinance::DataPresenter.new(household, user: user).send(:chat_message_page, before_id: nil, limit: 60)
    end

    assert_equal first_count, expanded_count
    assert_operator expanded_count, :<=, 4
    assert_equal 6, @expanded_page.fetch(:messages).sum { |message| message.fetch(:citations).length }
  end

  test "workspace keeps the full income source history while the annual plan stays year scoped" do
    travel_to Date.new(2026, 10, 15) do
      household, user = create_household
      ended = household.income_sources.create!(
        label: "Old contract", source_type: "business", amount_cents: 100_000, cadence: "monthly",
        starts_on: Date.new(2025, 1, 1), ends_on: Date.new(2025, 12, 1), active: false
      )
      current = household.income_sources.create!(
        label: "Current salary", source_type: "job", amount_cents: 500_000, cadence: "monthly", starts_on: Date.new(2026, 1, 1)
      )
      future = household.income_sources.create!(
        label: "Future contract", source_type: "business", amount_cents: 200_000, cadence: "monthly", starts_on: Date.new(2027, 2, 1)
      )

      payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
      collection = payload.dig(:workspace, :income_sources).index_by { |source| source.fetch(:id) }

      assert_equal [ ended.id, current.id, future.id ].sort, collection.keys.sort
      assert_equal "ended", collection.fetch(ended.id).fetch(:timeline_status)
      assert_equal "current", collection.fetch(current.id).fetch(:timeline_status)
      assert_equal "future", collection.fetch(future.id).fetch(:timeline_status)
      assert_equal [ current.id ], payload.dig(:budget, :annual_plan, :income_sources).pluck(:id)
    end
  end

  private

  def citation_query_count(&block)
    count = 0
    callback = lambda do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]
      next unless payload[:sql].match?(/coach_content_(?:citations|item_versions|items|pack_versions)/)

      count += 1
    end
    ActiveRecord::Base.connection.uncached do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    end
    count
  end

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
    household.household_profile.update!(
      debt_tracking_mode: "summary", debt_summary_balance_cents: 0,
      debt_summary_minimum_payment_cents: 0,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true
    )
    household.accounts.create!(label: "Known checking", account_type: "checking", balance_cents: 0, balance_known: true)

    [ household, user ]
  end

  def debt_milestone(payload)
    payload.dig(:wealth, :milestones).find { |milestone| milestone.fetch(:label) == "Debt payoff" }
  end

  def decision_map(payload)
    payload.dig(:cfoFilter, :decisions).index_by { |decision| decision.fetch(:item) }
  end
end
