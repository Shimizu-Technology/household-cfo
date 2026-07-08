require "test_helper"

class HouseholdFinanceTransactionDraftConfirmerTest < ActiveSupport::TestCase
  test "confirmation reuses category created by a concurrent draft confirmation" do
    user = create_user
    household = create_household(user)
    period = create_budget_period(household, Date.new(2026, 7, 5))
    draft = household.transaction_drafts.create!(
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Travel Vendor",
      total_amount_cents: 250_00,
      source_type: "receipt",
      status: "pending",
      raw_input: "Receipt row"
    )
    draft.transaction_draft_splits.create!(amount_cents: 250_00, category_name: "Travel", stack_key: "discretionary")
    confirmer = HouseholdFinance::TransactionDraftConfirmer.new(draft)
    confirmer.instance_variable_set(:@annual_budget_manager, race_manager_for(household, period))

    result = confirmer.call

    assert result.success?, result.errors.to_sentence
    category = household.budget_categories.find_by!(name: "Travel")
    assert_equal "confirmed", draft.reload.status
    assert_equal [ category.id ], result.transaction.transaction_splits.pluck(:budget_category_id)
    assert_equal 1, household.budget_categories.where("LOWER(name) = ?", "travel").count
  end

  private

  def create_user
    User.create!(
      clerk_id: "clerk_confirmer_#{SecureRandom.hex(4)}",
      email: "confirmer-#{SecureRandom.hex(4)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
  end

  def create_household(user)
    Household.create!(
      created_by_user: user,
      name: "Confirmer Household",
      location: "Guam",
      stage: "First cohort",
      primary_goal: "Review drafts safely."
    ).tap do |household|
      household.household_memberships.create!(user: user, role: "owner")
    end
  end

  def create_budget_period(household, date)
    budget_year = household.budget_years.create!(year: date.year, status: "active")
    budget_year.budget_periods.create!(starts_on: date.beginning_of_month, ends_on: date.end_of_month, status: "open")
  end

  def race_manager_for(household, period)
    Object.new.tap do |manager|
      manager.define_singleton_method(:current_period_for) { |_date| period }
      manager.define_singleton_method(:restore_category!) do |category|
        category.update!(active: true)
        category
      end
      manager.define_singleton_method(:create_category!) do |name:, stack_key:, monthly_amount: 0|
        household.budget_categories.create!(name: name, stack_key: stack_key, active: true, sort_order: 1)
        duplicate = household.budget_categories.new(name: name, stack_key: stack_key, active: true, sort_order: 2)
        duplicate.errors.add(:name, "already exists")
        raise ActiveRecord::RecordInvalid, duplicate
      end
    end
  end
end
