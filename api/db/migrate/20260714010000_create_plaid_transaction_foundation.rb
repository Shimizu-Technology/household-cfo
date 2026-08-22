class CreatePlaidTransactionFoundation < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :household_transactions, name: "household_transactions_source_type_valid"
    add_check_constraint :household_transactions, "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import', 'plaid')", name: "household_transactions_source_type_valid"
    remove_check_constraint :transaction_drafts, name: "transaction_drafts_source_type_valid"
    add_check_constraint :transaction_drafts, "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import', 'plaid')", name: "transaction_drafts_source_type_valid"

    create_table :plaid_items do |t|
      t.references :household, null: false, foreign_key: true
      t.references :connected_by_user, null: false, foreign_key: { to_table: :users }
      t.string :plaid_item_id, null: false
      t.text :access_token_ciphertext
      t.string :institution_id
      t.string :institution_name
      t.string :environment, null: false
      t.string :status, null: false, default: "active"
      t.text :sync_cursor
      t.datetime :consented_at, null: false
      t.string :consent_policy_version, null: false
      t.datetime :consent_expiration_time
      t.datetime :last_synced_at
      t.datetime :last_successful_update_at
      t.string :error_code
      t.string :error_message
      t.datetime :disconnected_at
      t.timestamps
    end
    add_index :plaid_items, :plaid_item_id, unique: true
    add_check_constraint :plaid_items, "environment IN ('sandbox', 'production')", name: "plaid_items_environment"
    add_check_constraint :plaid_items, "status IN ('active', 'update_required', 'error', 'disconnected')", name: "plaid_items_status"

    create_table :plaid_accounts do |t|
      t.references :plaid_item, null: false, foreign_key: true
      t.string :plaid_account_id, null: false
      t.string :persistent_account_id
      t.string :name, null: false
      t.string :official_name
      t.string :mask
      t.string :account_type, null: false
      t.string :account_subtype
      t.bigint :current_balance_cents
      t.bigint :available_balance_cents
      t.bigint :limit_balance_cents
      t.string :iso_currency_code
      t.boolean :active, null: false, default: true
      t.datetime :last_synced_at
      t.timestamps
    end
    add_index :plaid_accounts, :plaid_account_id, unique: true

    create_table :plaid_transactions do |t|
      t.references :plaid_item, null: false, foreign_key: true
      t.references :plaid_account, null: false, foreign_key: true
      t.references :transaction_draft, foreign_key: { on_delete: :nullify }
      t.string :plaid_transaction_id, null: false
      t.string :pending_transaction_id
      t.string :name, null: false
      t.string :merchant_name
      t.date :occurred_on, null: false
      t.date :authorized_on
      t.bigint :amount_cents, null: false
      t.boolean :pending, null: false, default: false
      t.string :primary_category
      t.string :detailed_category
      t.string :payment_channel
      t.string :iso_currency_code
      t.string :review_status, null: false, default: "unreviewed"
      t.string :source_fingerprint, null: false
      t.string :drafted_source_fingerprint
      t.datetime :removed_at
      t.timestamps
    end
    add_index :plaid_transactions, :plaid_transaction_id, unique: true
    add_index :plaid_transactions, [ :plaid_item_id, :occurred_on ]
    add_check_constraint :plaid_transactions, "review_status IN ('unreviewed', 'drafted', 'ignored')", name: "plaid_transactions_review_status"
  end

  def down
    drop_table :plaid_transactions
    drop_table :plaid_accounts
    drop_table :plaid_items

    remove_check_constraint :transaction_drafts, name: "transaction_drafts_source_type_valid"
    add_check_constraint :transaction_drafts, "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import')", name: "transaction_drafts_source_type_valid"
    remove_check_constraint :household_transactions, name: "household_transactions_source_type_valid"
    add_check_constraint :household_transactions, "source_type IN ('manual_chat', 'manual_ui', 'receipt', 'screenshot', 'statement', 'import')", name: "household_transactions_source_type_valid"
  end
end
