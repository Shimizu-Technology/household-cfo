require "test_helper"

class HouseholdTransactionTest < ActiveSupport::TestCase
  test "validate_split_total rejects mismatched splits" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "split-total@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    category = manager.create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 300)
    period = manager.current_period_for(Date.current)
    transaction = household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.current,
      merchant: "Cafe",
      total_amount_cents: 1_200,
      source_type: "manual_ui",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 900)

    error = assert_raises(ActiveRecord::RecordInvalid) { transaction.validate_split_total! }
    assert_includes error.record.errors.full_messages, "Transaction splits must equal transaction total"
  end
end
