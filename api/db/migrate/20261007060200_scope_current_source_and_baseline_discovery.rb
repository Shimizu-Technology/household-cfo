class ScopeCurrentSourceAndBaselineDiscovery < ActiveRecord::Migration[8.0]
  def change
    add_column :source_tracked_accounts, :financial_generation, :integer, default: 0, null: false
    add_column :financial_baseline_heads, :financial_generation, :integer, default: 0, null: false
    remove_index :financial_baseline_heads, name: :financial_baseline_participant_identity
    add_index :financial_baseline_heads, [ :household_id, :participant_user_id, :financial_generation ], unique: true, name: :financial_baseline_participant_identity
  end
end
