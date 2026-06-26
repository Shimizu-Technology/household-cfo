class CreateFinancialDocumentImportAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_document_import_attempts do |t|
      t.references :financial_document_import, null: false, foreign_key: true, index: { name: "index_financial_doc_attempts_on_import_id" }
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false
      t.string :prompt_version, null: false
      t.string :schema_version, null: false
      t.text :error
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :financial_document_import_attempts, [ :financial_document_import_id, :created_at ], name: "index_financial_doc_attempts_on_import_and_created"
    add_index :financial_document_import_attempts, :status
  end
end
