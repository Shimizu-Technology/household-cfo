class AddCaseInsensitiveBudgetCategoryIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :budget_categories,
      "household_id, LOWER(name)",
      unique: true,
      name: "index_budget_categories_on_household_lower_name"
  end
end
