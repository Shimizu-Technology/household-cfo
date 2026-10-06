class ScopeEconomicGroupsAfterFinancialRestart < ActiveRecord::Migration[8.0]
  def change
    add_column :source_economic_groups, :financial_generation, :integer, default: 0, null: false
  end
end
