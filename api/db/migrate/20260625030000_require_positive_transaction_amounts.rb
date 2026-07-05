class RequirePositiveTransactionAmounts < ActiveRecord::Migration[8.1]
  def up
    replace_check_constraint(
      :household_transactions,
      old_name: "household_transactions_amount_non_negative",
      new_name: "household_transactions_amount_positive",
      expression: "total_amount_cents > 0"
    )
    replace_check_constraint(
      :transaction_splits,
      old_name: "transaction_splits_amount_non_negative",
      new_name: "transaction_splits_amount_positive",
      expression: "amount_cents > 0"
    )
    replace_check_constraint(
      :transaction_drafts,
      old_name: "transaction_drafts_amount_non_negative",
      new_name: "transaction_drafts_amount_positive",
      expression: "total_amount_cents > 0"
    )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "transaction amounts must remain strictly positive"
  end

  private

  def replace_check_constraint(table, old_name:, new_name:, expression:)
    remove_check_constraint(table, name: old_name) if check_constraint_exists?(table, name: old_name)
    remove_check_constraint(table, name: new_name) if check_constraint_exists?(table, name: new_name)
    add_check_constraint(table, expression, name: new_name)
  end
end
