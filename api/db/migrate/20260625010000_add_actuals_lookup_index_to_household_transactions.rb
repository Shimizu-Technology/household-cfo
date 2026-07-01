class AddActualsLookupIndexToHouseholdTransactions < ActiveRecord::Migration[8.1]
  def change
    add_index :household_transactions,
      [ :budget_period_id, :status ],
      name: "index_household_transactions_on_budget_period_status"
  end
end
