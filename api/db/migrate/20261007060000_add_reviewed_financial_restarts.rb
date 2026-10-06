class AddReviewedFinancialRestarts < ActiveRecord::Migration[8.0]
  ROOTS = %w[income_sources expense_items debts accounts goals budget_years budget_categories household_transactions transaction_drafts mia_action_drafts merchant_category_rules].freeze
  INDEXES = {
    "income_sources" => [ [ "index_income_sources_on_household_type_lower_label", "household_id, financial_generation, source_type, lower(label)", "active = true" ] ],
    "expense_items" => [ [ "index_expense_items_on_household_stack_key_label", "household_id, financial_generation, stack_key, label", nil ] ],
    "debts" => [ [ "index_active_debts_on_household_type_label", "household_id, financial_generation, debt_type, lower(label)", "active = true" ] ],
    "accounts" => [ [ "index_active_accounts_on_household_type_label", "household_id, financial_generation, account_type, lower(label)", "active = true" ] ],
    "goals" => [ [ "index_goals_on_one_runway_per_household", "household_id, financial_generation", "goal_type = 'runway'" ], [ "index_goals_on_one_transition_per_household", "household_id, financial_generation", "goal_type = 'transition'" ] ],
    "budget_years" => [ [ "index_budget_years_on_household_id_and_year", "household_id, financial_generation, year", nil ] ],
    "budget_categories" => [ [ "index_budget_categories_on_household_lower_name", "household_id, financial_generation, lower(name)", nil ] ],
    "merchant_category_rules" => [ [ "index_merchant_rules_on_household_pattern_category", "household_id, financial_generation, merchant_pattern, budget_category_id", nil ] ]
  }.freeze

  def up
    add_column :households, :financial_generation, :integer, default: 0, null: false
    (ROOTS + %w[household_profiles financial_document_imports plaid_items chat_messages household_memories household_operation_executions]).each do |table|
      add_column table, :financial_generation, :integer, default: 0, null: false
    end
    create_table :financial_restart_reviews do |t|
      t.references :household, null: false, foreign_key: true
      t.references :requested_by_user, null: false, foreign_key: { to_table: :users }
      t.references :cohort, foreign_key: true
      t.integer :financial_generation, null: false
      t.string :status, null: false, default: "pending"
      t.string :inventory_fingerprint, null: false
      t.jsonb :inventory, null: false, default: {}
      t.jsonb :previous_setup, null: false, default: {}
      t.datetime :expires_at, null: false
      t.datetime :applied_at
      t.integer :result_generation
      t.timestamps
    end
    INDEXES.each do |table, indexes|
      indexes.each do |name, columns, predicate|
        remove_index table, name: name
        execute "CREATE UNIQUE INDEX #{name} ON #{table} (#{columns})#{predicate ? " WHERE #{predicate}" : ''}"
      end
    end
    execute <<~SQL
      CREATE FUNCTION financial_picture_write_guard() RETURNS trigger AS $$
      DECLARE current_generation integer;
      BEGIN
        SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
        IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
          RAISE EXCEPTION 'financial_generation_stale: reload the current financial picture' USING ERRCODE = '23514';
        END IF;
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME <> 'household_profiles' AND
            (NEW.financial_generation IS DISTINCT FROM OLD.financial_generation OR NEW.household_id IS DISTINCT FROM OLD.household_id) THEN
          RAISE EXCEPTION 'financial picture identity cannot change' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    (ROOTS + %w[household_profiles]).each do |table|
      execute "CREATE TRIGGER #{table}_financial_picture_guard BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard()"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Financial restart history cannot be discarded" if select_value("SELECT EXISTS (SELECT 1 FROM financial_restart_reviews)")
    (ROOTS + %w[household_profiles]).each { |table| execute "DROP TRIGGER #{table}_financial_picture_guard ON #{table}" }
    execute "DROP FUNCTION financial_picture_write_guard()"
    INDEXES.each do |table, indexes|
      indexes.each do |name, columns, predicate|
        remove_index table, name: name
        execute "CREATE UNIQUE INDEX #{name} ON #{table} (#{columns.gsub(', financial_generation', '')})#{predicate ? " WHERE #{predicate}" : ''}"
      end
    end
    drop_table :financial_restart_reviews
    (ROOTS + %w[household_profiles financial_document_imports plaid_items chat_messages household_memories household_operation_executions households]).each { |table| remove_column table, :financial_generation }
  end
end
