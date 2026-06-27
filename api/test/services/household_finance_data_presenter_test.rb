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
  end

  test "debt free household with real inputs keeps debt milestone green" do
    household, user = create_household
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 250_000, cadence: "monthly")

    payload = HouseholdFinance::DataPresenter.new(household, user: user).app_data

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
