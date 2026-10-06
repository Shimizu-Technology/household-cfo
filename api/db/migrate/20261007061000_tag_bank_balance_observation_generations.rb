class TagBankBalanceObservationGenerations < ActiveRecord::Migration[8.0]
  def change
    add_column :plaid_accounts, :financial_generation, :integer, default: 0, null: false
  end
end
