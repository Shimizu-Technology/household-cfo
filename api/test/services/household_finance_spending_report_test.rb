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

  test "pending totals allocate split drafts by split category without losing uncategorized money" do
    household = create_household
    dining = household.budget_categories.create!(name: "Dining", stack_key: "discretionary", sort_order: 1)
    groceries = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 2)
    draft = household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 10),
      merchant: "Split receipt",
      total_amount_cents: 10_000,
      status: "pending",
      source_type: "receipt"
    )
    draft.transaction_draft_splits.create!(budget_category: dining, category_name: dining.name, amount_cents: 6_000)
    draft.transaction_draft_splits.create!(category_name: "Needs category", amount_cents: 4_000)
    unsplit = household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 11),
      merchant: "Unsplit groceries",
      total_amount_cents: 2_500,
      budget_category: groceries,
      status: "pending",
      source_type: "manual_ui"
    )

    payload = HouseholdFinance::SpendingReport.new(
      household,
      start_on: Date.new(2026, 7, 1),
      end_on: Date.new(2026, 7, 31)
    ).as_json

    assert_equal 125.0, payload.dig(:totals, :pending)
    assert_equal 60.0, payload.fetch(:categories).find { |row| row[:id] == dining.id }.fetch(:pending)
    assert_equal 25.0, payload.fetch(:categories).find { |row| row[:id] == groceries.id }.fetch(:pending)
    assert_equal 40.0, payload.fetch(:categories).find { |row| row[:id].zero? }.fetch(:pending)
    assert_equal 2, payload.fetch(:pending_drafts).length
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
