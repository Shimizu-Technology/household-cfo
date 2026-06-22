class CreateHouseholdWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :households do |t|
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :location
      t.string :stage
      t.text :primary_goal

      t.timestamps
    end

    create_table :household_memberships do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "owner"

      t.timestamps
    end
    add_index :household_memberships, [ :household_id, :user_id ], unique: true
    add_index :household_memberships, :role
    add_index :household_memberships, :user_id,
      unique: true,
      where: "role = 'owner'",
      name: "index_household_memberships_on_one_owner_per_user"

    create_table :household_profiles do |t|
      t.references :household, null: false, foreign_key: true, index: { unique: true }
      t.string :household_stage
      t.integer :money_stress_level
      t.text :primary_decision
      t.text :notes

      t.timestamps
    end

    create_table :income_sources do |t|
      t.references :household, null: false, foreign_key: true
      t.string :label, null: false
      t.integer :amount_cents, null: false, default: 0
      t.string :cadence, null: false, default: "monthly"
      t.string :source_type, null: false, default: "other"
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :income_sources, [ :household_id, :active ]
    add_index :income_sources, [ :household_id, :source_type ]
    add_index :income_sources, [ :household_id, :source_type, :label ], unique: true, name: "index_income_sources_on_household_source_type_label"
    add_check_constraint :income_sources, "amount_cents >= 0", name: "income_sources_amount_cents_non_negative"

    create_table :expense_items do |t|
      t.references :household, null: false, foreign_key: true
      t.string :label, null: false
      t.integer :amount_cents, null: false, default: 0
      t.string :cadence, null: false, default: "monthly"
      t.string :stack_key, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :expense_items, [ :household_id, :active ]
    add_index :expense_items, [ :household_id, :stack_key ]
    add_index :expense_items, [ :household_id, :stack_key, :label ], unique: true, name: "index_expense_items_on_household_stack_key_label"

    create_table :debts do |t|
      t.references :household, null: false, foreign_key: true
      t.string :label, null: false
      t.integer :balance_cents, null: false, default: 0
      t.integer :minimum_payment_cents, null: false, default: 0
      t.decimal :interest_rate_percent, precision: 6, scale: 2
      t.string :debt_type, null: false, default: "other"

      t.timestamps
    end
    add_index :debts, [ :household_id, :debt_type ]
    add_index :debts, [ :household_id, :debt_type, :label ], unique: true, name: "index_debts_on_household_debt_type_label"

    create_table :accounts do |t|
      t.references :household, null: false, foreign_key: true
      t.string :label, null: false
      t.string :account_type, null: false, default: "other"
      t.integer :balance_cents, null: false, default: 0

      t.timestamps
    end
    add_index :accounts, [ :household_id, :account_type ]
    add_index :accounts, [ :household_id, :account_type, :label ], unique: true, name: "index_accounts_on_household_account_type_label"

    create_table :goals do |t|
      t.references :household, null: false, foreign_key: true
      t.string :label, null: false
      t.string :goal_type, null: false, default: "other"
      t.integer :target_amount_cents, null: false, default: 0
      t.integer :current_amount_cents, null: false, default: 0
      t.decimal :target_months, precision: 6, scale: 2
      t.integer :priority, null: false, default: 0

      t.timestamps
    end
    add_index :goals, [ :household_id, :goal_type ]
    add_index :goals, [ :household_id, :priority ]
    add_index :goals, :household_id, unique: true, where: "goal_type = 'runway'", name: "index_goals_on_one_runway_per_household"
    add_index :goals, :household_id, unique: true, where: "goal_type = 'transition'", name: "index_goals_on_one_transition_per_household"

    create_table :chat_sessions do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title

      t.timestamps
    end
    add_index :chat_sessions, [ :household_id, :user_id ], unique: true

    create_table :chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false

      t.timestamps
    end
    add_index :chat_messages, [ :chat_session_id, :created_at ]
    add_index :chat_messages, :role
  end
end
