class CreateDocumentIntelligenceTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :transaction_drafts, :matched_transaction, foreign_key: { to_table: :household_transactions }
    add_index :transaction_drafts, [ :financial_document_import_id, :status ], name: "index_transaction_drafts_on_import_and_status"

    reversible do |dir|
      dir.up do
        remove_check_constraint :transaction_drafts, name: "transaction_drafts_status_valid"
        add_check_constraint :transaction_drafts,
          "status IN ('pending', 'confirmed', 'corrected', 'ignored', 'matched')",
          name: "transaction_drafts_status_valid"
      end
      dir.down do
        execute "UPDATE transaction_drafts SET status = 'ignored' WHERE status = 'matched'"
        remove_check_constraint :transaction_drafts, name: "transaction_drafts_status_valid"
        add_check_constraint :transaction_drafts,
          "status IN ('pending', 'confirmed', 'corrected', 'ignored')",
          name: "transaction_drafts_status_valid"
      end
    end

    create_table :transaction_draft_splits do |t|
      t.references :transaction_draft, null: false, foreign_key: true
      t.references :budget_category, foreign_key: true
      t.integer :amount_cents, null: false
      t.string :category_name
      t.string :stack_key
      t.text :notes
      t.decimal :confidence, precision: 5, scale: 2
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :transaction_draft_id, :budget_category_id ], name: "index_draft_splits_on_draft_and_category"
      t.check_constraint "amount_cents > 0", name: "transaction_draft_splits_amount_positive"
      t.check_constraint "stack_key IS NULL OR stack_key IN ('non_discretionary', 'discretionary', 'sinking_expected', 'sinking_unexpected')", name: "transaction_draft_splits_stack_key_valid"
    end

    create_table :transaction_draft_matches do |t|
      t.references :transaction_draft, null: false, foreign_key: true
      t.references :household_transaction, null: false, foreign_key: true
      t.string :status, null: false, default: "proposed"
      t.decimal :confidence, precision: 5, scale: 2
      t.string :match_reason
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :transaction_draft_id, :household_transaction_id ], unique: true, name: "index_draft_matches_on_draft_and_transaction"
      t.index [ :household_transaction_id, :status ], name: "index_draft_matches_on_transaction_and_status"
      t.check_constraint "status IN ('proposed', 'accepted', 'rejected')", name: "transaction_draft_matches_status_valid"
    end

    create_table :merchant_category_rules do |t|
      t.references :household, null: false, foreign_key: true
      t.references :budget_category, null: false, foreign_key: true
      t.string :merchant_pattern, null: false
      t.decimal :confidence, precision: 5, scale: 2, null: false, default: 0.80
      t.string :source, null: false, default: "user_confirmed"
      t.integer :times_confirmed, null: false, default: 1
      t.datetime :last_confirmed_at
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [ :household_id, :merchant_pattern, :budget_category_id ], unique: true, name: "index_merchant_rules_on_household_pattern_category"
      t.index [ :household_id, :active, :merchant_pattern ], name: "index_merchant_rules_on_household_active_pattern"
      t.check_constraint "confidence >= 0 AND confidence <= 1", name: "merchant_category_rules_confidence_unit_interval"
      t.check_constraint "source IN ('user_confirmed', 'system_inferred', 'coach_confirmed')", name: "merchant_category_rules_source_valid"
      t.check_constraint "times_confirmed >= 0", name: "merchant_category_rules_times_confirmed_non_negative"
      t.check_constraint "char_length(merchant_pattern) <= 120", name: "merchant_category_rules_pattern_length"
    end
  end
end
