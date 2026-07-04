require "test_helper"

class HouseholdFinanceSpendingReportTest < ActiveSupport::TestCase
  test "existing report-ready plans do not take the household lock on read" do
    household = create_household
    household.expense_items.create!(label: "Dining", stack_key: "discretionary", amount_cents: 20_000, cadence: "monthly")
    HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).plan_data

    report = HouseholdFinance::SpendingReport.new(
      household,
      start_on: Date.new(2026, 7, 1),
      end_on: Date.new(2026, 7, 31)
    )

    original_with_lock = household.method(:with_lock)
    household.define_singleton_method(:with_lock) do |*|
      raise "report should not lock an already-ready plan"
    end

    payload = report.as_json
    assert_equal "July 2026", payload.fetch(:period_label)
    assert_equal 200.0, payload.fetch(:totals).fetch(:planned)
  ensure
    if defined?(original_with_lock) && original_with_lock
      household&.define_singleton_method(:with_lock) do |*args, &block|
        original_with_lock.call(*args, &block)
      end
    end
  end

  test "missing report plans are bootstrapped once" do
    household = create_household
    household.expense_items.create!(label: "Dining", stack_key: "discretionary", amount_cents: 20_000, cadence: "monthly")

    payload = HouseholdFinance::SpendingReport.new(
      household,
      start_on: Date.new(2027, 7, 1),
      end_on: Date.new(2027, 7, 31)
    ).as_json

    assert_equal "July 2027", payload.fetch(:period_label)
    assert_equal 200.0, payload.fetch(:totals).fetch(:planned)
    assert_equal 1, household.budget_years.where(year: 2027).count
    assert_equal 12, household.budget_years.find_by!(year: 2027).budget_periods.count
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
