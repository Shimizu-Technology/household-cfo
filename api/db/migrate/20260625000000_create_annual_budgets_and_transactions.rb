class CreateAnnualBudgetsAndTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_years do |t|
      t.references :household, null: false, foreign_key: true
      t.integer :year, null: false
      t.string :status, null: false, default: "active"
      t.timestamps

      t.index [ :household_id, :year ], unique: true
      t.check_constraint "year >= 2000 AND year <= 2100", name: "budget_years_year_reasonable"
      t.check_constraint "status IN ('draft', 'active', 'archived')", name: "budget_years_status_valid"
    end

    create_table :budget_periods do |t|
      t.references :budget_year, null: false, foreign_key: true
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :status, null: false, default: "open"
      t.timestamps

      t.index [ :budget_year_id, :starts_on ], unique: true
      t.check_constraint "ends_on >= starts_on", name: "budget_periods_dates_ordered"
      t.check_constraint "status IN ('open', 'reviewing', 'closed')", name: "budget_periods_status_valid"
    end

    create_table :budget_categories do |t|
      t.references :household, null: false, foreign_key: true
      t.string :name, null: false
      t.string :stack_key, null: false
      t.boolean :active, null: false, default: true
      t.integer :sort_order, null: false, default: 0
      t.timestamps

      t.index [ :household_id, :active, :sort_order ]
      t.check_constraint "stack_key IN ('non_discretionary', 'discretionary', 'sinking_expected', 'sinking_unexpected')", name: "budget_categories_stack_key_valid"
      t.check_constraint "char_length(name) <= 80", name: "budget_categories_name_length"
    end

    create_table :budget_allocations do |t|
      t.references :budget_period, null: false, foreign_key: true
      t.references :budget_category, null: false, foreign_key: true
      t.integer :planned_amount_cents, null: false, default: 0
      t.string :source, null: false, default: "manual"
      t.timestamps

      t.index [ :budget_period_id, :budget_category_id ], unique: true
      t.check_constraint "planned_amount_cents >= 0", name: "budget_allocations_amount_non_negative"
      t.check_constraint "source IN ('manual', 'setup', 'imported', 'mia_suggested')", name: "budget_allocations_source_valid"
    end

    create_table :household_transactions do |t|
      t.references :household, null: false, foreign_key: true
      t.references :budget_period, null: false, foreign_key: true
      t.references :source_import, foreign_key: { to_table: :financial_document_imports }
      t.date :occurred_on, null: false
      t.string :merchant, null: false
      t.text :description
      t.integer :total_amount_cents, null: false
      t.string :source_type, null: false, default: "manual_chat"
      t.string :status, null: false, default: "confirmed"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :household_id, :occurred_on ]
      t.index [ :household_id, :status ]
      t.check_constraint "total_amount_cents >= 0", name: "household_transactions_amount_non_negative"
      t.check_constraint "status IN ('confirmed', 'reconciled', 'ignored')", name: "household_transactions_status_valid"
      t.check_constraint "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import')", name: "household_transactions_source_type_valid"
    end

    create_table :transaction_splits do |t|
      t.references :household_transaction, null: false, foreign_key: true
      t.references :budget_category, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.text :notes
      t.timestamps

      t.index [ :household_transaction_id, :budget_category_id ], name: "index_transaction_splits_on_transaction_and_category"
      t.check_constraint "amount_cents >= 0", name: "transaction_splits_amount_non_negative"
    end

    create_table :transaction_drafts do |t|
      t.references :household, null: false, foreign_key: true
      t.references :budget_category, foreign_key: true
      t.references :financial_document_import, foreign_key: true
      t.references :confirmed_transaction, foreign_key: { to_table: :household_transactions }
      t.date :occurred_on, null: false
      t.string :merchant, null: false
      t.integer :total_amount_cents, null: false
      t.string :status, null: false, default: "pending"
      t.string :source_type, null: false, default: "manual_chat"
      t.decimal :confidence, precision: 5, scale: 2
      t.text :raw_input
      t.jsonb :draft_payload, null: false, default: {}
      t.timestamps

      t.index [ :household_id, :status, :created_at ]
      t.check_constraint "total_amount_cents >= 0", name: "transaction_drafts_amount_non_negative"
      t.check_constraint "status IN ('pending', 'confirmed', 'corrected', 'ignored')", name: "transaction_drafts_status_valid"
      t.check_constraint "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import')", name: "transaction_drafts_source_type_valid"
    end
  end
end
