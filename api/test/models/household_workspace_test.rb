require "test_helper"

class HouseholdWorkspaceTest < ActiveSupport::TestCase
  test "workspace resolver returns one owner household per user" do
    user = create_user

    first_household = HouseholdFinance::WorkspaceResolver.new(user).household
    second_household = HouseholdFinance::WorkspaceResolver.new(user).household

    assert_equal first_household, second_household
    assert_equal 1, HouseholdMembership.where(user: user, role: "owner").count
  end

  test "a user cannot own two households" do
    user = create_user
    first_household = HouseholdFinance::WorkspaceResolver.new(user).household
    second_household = Household.create!(created_by_user: user, name: "Second household")

    membership = second_household.household_memberships.build(user: user, role: "owner")

    assert_not membership.valid?
    assert_includes membership.errors[:user_id], "already owns a household"
    assert_equal first_household, user.households.first
  end

  test "chat sessions are unique per household and user" do
    user = create_user
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    household.chat_sessions.create!(user: user, title: "Ask Mia")

    duplicate = household.chat_sessions.build(user: user, title: "Second Ask Mia")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "setup-managed rows are unique per household" do
    household = HouseholdFinance::WorkspaceResolver.new(create_user).household
    household.income_sources.create!(label: "Primary income", source_type: "job", cadence: "monthly", amount_cents: 100_000)
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", cadence: "monthly", amount_cents: 50_000)
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_000_000)
    household.debts.create!(label: "Credit card debt", debt_type: "credit_card", balance_cents: 200_000)
    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 6)

    assert_not household.income_sources.build(label: "Primary income", source_type: "job", cadence: "monthly", amount_cents: 100_000).valid?
    assert_not household.expense_items.build(label: "Fixed essentials", stack_key: "non_discretionary", cadence: "monthly", amount_cents: 50_000).valid?
    assert_not household.accounts.build(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 1_000_000).valid?
    assert_not household.debts.build(label: "Credit card debt", debt_type: "credit_card", balance_cents: 200_000).valid?
    assert_not household.goals.build(label: "Different runway target", goal_type: "runway", target_months: 12).valid?
  end

  test "income source amounts must be non-negative" do
    household = HouseholdFinance::WorkspaceResolver.new(create_user).household
    income_source = household.income_sources.build(
      label: "Primary income",
      source_type: "job",
      cadence: "monthly",
      amount_cents: -1
    )

    assert_not income_source.valid?
    assert_includes income_source.errors[:amount_cents], "must be greater than or equal to 0"
  end

  private

  def create_user
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
  end
end
