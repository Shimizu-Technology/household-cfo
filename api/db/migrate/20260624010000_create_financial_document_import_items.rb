class CreateFinancialDocumentImportItems < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_document_import_items do |t|
      t.references :financial_document_import, null: false, foreign_key: true, index: { name: "index_financial_doc_items_on_import_id" }
      t.references :applied_by_user, foreign_key: { to_table: :users }
      t.string :target_type, null: false
      t.string :label, null: false
      t.integer :amount_cents
      t.integer :balance_cents
      t.integer :payment_cents
      t.string :cadence
      t.string :source_type
      t.string :stack_key
      t.string :account_type
      t.string :debt_type
      t.string :confidence
      t.text :evidence
      t.boolean :selected, null: false, default: true
      t.boolean :ignored, null: false, default: false
      t.datetime :applied_at
      t.string :applied_record_type
      t.bigint :applied_record_id
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :financial_document_import_items, [ :financial_document_import_id, :target_type ], name: "index_financial_doc_items_on_import_and_target"
    add_index :financial_document_import_items, [ :applied_record_type, :applied_record_id ], name: "index_financial_doc_items_on_applied_record"
    add_index :financial_document_import_items, :selected
    add_index :financial_document_import_items, :ignored
    add_check_constraint :financial_document_import_items, "amount_cents IS NULL OR amount_cents >= 0", name: "financial_doc_items_amount_cents_non_negative"
    add_check_constraint :financial_document_import_items, "balance_cents IS NULL OR balance_cents >= 0", name: "financial_doc_items_balance_cents_non_negative"
    add_check_constraint :financial_document_import_items, "payment_cents IS NULL OR payment_cents >= 0", name: "financial_doc_items_payment_cents_non_negative"
  end
end
