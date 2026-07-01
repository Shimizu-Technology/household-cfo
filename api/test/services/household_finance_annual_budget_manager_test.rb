require "test_helper"

class HouseholdFinanceAnnualBudgetManagerTest < ActiveSupport::TestCase
  test "plan data degrades gracefully when a memoized manager sees a missing allocation" do
    household = create_household
    household.expense_items.create!(label: "Dining out", stack_key: "discretionary", amount_cents: 25_000, cadence: "monthly")
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    plan = manager.plan_data
    row = plan.fetch(:rows).find { |candidate| candidate.fetch(:name) == "Dining out" }
    first_month = row.fetch(:months).first

    BudgetAllocation.find(first_month.fetch(:allocation_id)).destroy!

    repaired_plan = manager.plan_data
    repaired_row = repaired_plan.fetch(:rows).find { |candidate| candidate.fetch(:name) == "Dining out" }
    repaired_month = repaired_row.fetch(:months).find { |month| month.fetch(:period_id) == first_month.fetch(:period_id) }

    assert_equal 12, repaired_row.fetch(:months).length
    assert_nil repaired_month.fetch(:allocation_id)
    assert_equal true, repaired_month.fetch(:allocation_missing)
    assert_equal 0, repaired_month.fetch(:planned)
  end

  private

  def create_household
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    Household.create!(
      created_by_user: user,
      name: "Test household",
      primary_goal: "Build a clear monthly money rhythm."
    ).tap do |household|
      household.household_memberships.create!(user: user, role: "owner")
    end
  end
end
