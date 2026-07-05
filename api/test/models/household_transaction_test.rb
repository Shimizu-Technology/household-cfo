require "test_helper"

class HouseholdTransactionTest < ActiveSupport::TestCase
  test "transactions and splits require positive amounts" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "positive-transaction-amount@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    manager = HouseholdFinance::AnnualBudgetManager.new(household)
    category = manager.create_category!(name: "Dining", stack_key: "discretionary", monthly_amount: 300)
    period = manager.current_period_for(Date.current)
    transaction = household.household_transactions.build(
      budget_period: period,
      occurred_on: Date.current,
      merchant: "Cafe",
      total_amount_cents: 0,
      source_type: "manual_ui",
      status: "confirmed"
    )

    assert_not transaction.valid?
    assert_includes transaction.errors[:total_amount_cents], "must be greater than 0"

    transaction.total_amount_cents = 1_200
    transaction.save!
    split = transaction.transaction_splits.build(budget_category: category, amount_cents: 0)

    assert_not split.valid?
    assert_includes split.errors[:amount_cents], "must be greater than 0"
  end

  test "transaction drafts require positive amounts" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "positive-draft-amount@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    draft = household.transaction_drafts.build(
      occurred_on: Date.current,
      merchant: "Cafe",
      total_amount_cents: 0,
      source_type: "manual_chat",
      status: "pending"
    )

    assert_not draft.valid?
    assert_includes draft.errors[:total_amount_cents], "must be greater than 0"
  end

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
