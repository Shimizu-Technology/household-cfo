require "test_helper"

class HouseholdFinanceDataPresenterTest < ActiveSupport::TestCase
  test "blank workspace does not invent debt or CFO filter amounts" do
    household, user = create_household

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data
    debt_milestone = debt_milestone(payload)
    decisions = decision_map(payload)

    assert_equal 0, debt_milestone.fetch(:current)
    assert_equal 0, debt_milestone.fetch(:target)
    assert_equal "dollars entered", debt_milestone.fetch(:unit)
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

    assert_equal 1, debt_milestone(payload).fetch(:current)
    assert_equal 1, debt_milestone(payload).fetch(:target)
    assert_equal "clear", debt_milestone(payload).fetch(:unit)
    assert_equal "green", debt_milestone(payload).fetch(:status)
  end

  test "deficit household does not show a negative non-essential purchase amount" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 200_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 250_000, cadence: "monthly")

    decisions = decision_map(HouseholdFinance::DataPresenter.new(household, user: user).app_data)

    assert_equal 0, decisions.fetch("Non-essential purchase").fetch(:amount)
    assert_equal "Wait", decisions.fetch("Non-essential purchase").fetch(:recommendation)
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
    household.mia_action_drafts.create!(
      requested_by_user: user,
      year: Date.current.year,
      draft_type: "budget_edit",
      status: "pending",
      title: "Review budget",
      summary: "Review a planned change"
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
    payload.dig(:wealth, :milestones).find { |milestone| milestone.fetch(:label) == "Debt entered" }
  end

  def decision_map(payload)
    payload.dig(:cfoFilter, :decisions).index_by { |decision| decision.fetch(:item) }
  end
end
