require "test_helper"

class HouseholdFinanceTransactionDraftConfirmerTest < ActiveSupport::TestCase
  test "document receipt confirmation requires an explicit category for every split" do
    user = create_user
    household = create_household(user)
    groceries = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "needs_review",
      filename: "mixed-receipt.png",
      content_type: "image/png",
      byte_size: 100,
      s3_key: "household-cfo/test/mixed-receipt.png"
    )
    draft = document_import.transaction_drafts.create!(
      household: household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Tita's Demo Market",
      total_amount_cents: 1_125,
      source_type: "receipt",
      status: "pending",
      raw_input: "Tobacco line"
    )
    split = draft.transaction_draft_splits.create!(amount_cents: 1_125, category_name: "Cigarettes", stack_key: "discretionary")

    result = HouseholdFinance::TransactionDraftConfirmer.new(draft).call

    refute result.success?
    assert_includes result.errors, "Choose a category for every receipt or document split before confirming."
    assert_equal "pending", draft.reload.status
    assert_equal 0, household.household_transactions.count

    split.update!(budget_category: groceries)
    confirmed = HouseholdFinance::TransactionDraftConfirmer.new(draft).call

    assert confirmed.success?, confirmed.errors.to_sentence
    assert_equal groceries.id, confirmed.transaction.transaction_splits.first.budget_category_id
  end

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
