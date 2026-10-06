class IsolateResumedBankActivity < ActiveRecord::Migration[8.0]
  def up
    add_column :plaid_transactions, :financial_generation, :integer, default: 0, null: false
    add_column :plaid_items, :financial_resumed_at, :datetime
    remove_index :accounts, name: :index_accounts_on_unique_plaid_account
    add_index :accounts, [ :plaid_account_id, :financial_generation ], unique: true, where: "plaid_account_id IS NOT NULL", name: :index_accounts_on_unique_plaid_account
    execute <<~SQL
      CREATE FUNCTION bank_activity_generation_guard() RETURNS trigger AS $$
      BEGIN
        IF NEW.financial_generation IS DISTINCT FROM OLD.financial_generation OR NEW.plaid_item_id IS DISTINCT FROM OLD.plaid_item_id THEN
          RAISE EXCEPTION 'bank activity financial generation cannot change' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER plaid_transactions_financial_generation_guard BEFORE UPDATE ON plaid_transactions FOR EACH ROW EXECUTE FUNCTION bank_activity_generation_guard();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retained bank activity cannot be reassigned to an earlier financial picture"
  end
end
