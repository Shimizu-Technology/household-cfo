require "test_helper"

class HouseholdFinanceAnnualBudgetManagerTest < ActiveSupport::TestCase
  test "plan data scopes pending transaction drafts to the viewed budget year" do
    household = create_household
    household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 1),
      merchant: "Current Cafe",
      total_amount_cents: 1_100,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $11 at Current Cafe"
    )
    household.transaction_drafts.create!(
      occurred_on: Date.new(2025, 7, 1),
      merchant: "Prior Cafe",
      total_amount_cents: 1_200,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent $12 at Prior Cafe"
    )

    current_plan = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).plan_data
    prior_plan = HouseholdFinance::AnnualBudgetManager.new(household, year: 2025).plan_data

    assert_equal [ "Current Cafe" ], current_plan.fetch(:pending_transaction_drafts).map { |draft| draft.fetch(:merchant) }
    assert_equal [ "Prior Cafe" ], prior_plan.fetch(:pending_transaction_drafts).map { |draft| draft.fetch(:merchant) }
  end

  test "plan data returns more than twenty pending statement drafts for paginated review" do
    household = create_household
    25.times do |index|
      household.transaction_drafts.create!(
        occurred_on: Date.new(2026, 7, (index % 28) + 1),
        merchant: "Statement Merchant #{index + 1}",
        total_amount_cents: (index + 1) * 100,
        source_type: "statement",
        status: "pending",
        raw_input: "Statement row #{index + 1}"
      )
    end

    plan = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026).plan_data

    assert_equal 25, plan.fetch(:pending_transaction_drafts).length
    assert_equal "Statement Merchant 25", plan.fetch(:pending_transaction_drafts).first.fetch(:merchant)
  end

  test "budget allocation upsert recovers from uniqueness races" do
    household = create_household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    budget_year = manager.ensure_plan!
    period = budget_year.budget_periods.order(:starts_on).first
    category = household.budget_categories.create!(name: "Race Category", stack_key: "discretionary", sort_order: 1)
    allocation = BudgetAllocation.create!(budget_period: period, budget_category: category, planned_amount_cents: 100, source: "manual")
    original_find_or_initialize_by = BudgetAllocation.method(:find_or_initialize_by)
    calls = 0

    BudgetAllocation.define_singleton_method(:find_or_initialize_by) do |*args, **kwargs|
      calls += 1
      raise ActiveRecord::RecordNotUnique, "simulated allocation race" if calls == 1

      original_find_or_initialize_by.call(*args, **kwargs)
    end

    manager.send(:upsert_budget_allocation!, period, category, 12_345, "manual")

    assert_equal 12_345, allocation.reload.planned_amount_cents
  ensure
    if defined?(original_find_or_initialize_by) && original_find_or_initialize_by
      BudgetAllocation.define_singleton_method(:find_or_initialize_by) do |*args, **kwargs|
        original_find_or_initialize_by.call(*args, **kwargs)
      end
    end
  end

  test "current period heals a missing period from a memoized manager" do
    household = create_household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    budget_year = manager.ensure_plan!
    july = budget_year.budget_periods.find_by!(starts_on: Date.new(2026, 7, 1))
    july.destroy!

    repaired = manager.current_period_for(Date.new(2026, 7, 15))

    assert_equal Date.new(2026, 7, 1), repaired.starts_on
    assert_equal Date.new(2026, 7, 31), repaired.ends_on
  end

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

  test "archived actual history without allocations does not emit missing allocation warnings" do
    household = create_household
    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    period = manager.current_period_for(Date.new(2026, 7, 15))
    category = household.budget_categories.create!(name: "Archived History", stack_key: "discretionary", active: false, sort_order: 1)
    transaction = household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 15),
      merchant: "Legacy Cafe",
      total_amount_cents: 1_200,
      source_type: "manual_ui",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_200)
    fake_logger = Class.new do
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message)
        @warnings << message
      end

      def method_missing(*)
        nil
      end

      def respond_to_missing?(*alt)
        true
      end
    end.new
    original_logger = Rails.logger
    Rails.logger = fake_logger

    plan = manager.plan_data

    assert_empty fake_logger.warnings
    archived_row = plan.fetch(:rows).find { |row| row.fetch(:name) == "Archived History" }
    assert_equal false, archived_row.fetch(:active)
    assert_equal 12, archived_row.fetch(:actual_total)
  ensure
    Rails.logger = original_logger if defined?(original_logger) && original_logger
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
