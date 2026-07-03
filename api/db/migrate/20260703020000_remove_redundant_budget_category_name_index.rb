class RemoveRedundantBudgetCategoryNameIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :budget_categories,
      name: "index_budget_categories_on_household_id_and_name",
      if_exists: true
  end
end
