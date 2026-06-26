class CreateFinancialDocumentImports < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_document_imports do |t|
      t.references :household, null: false, foreign_key: true
      t.references :uploaded_by_user, null: false, foreign_key: { to_table: :users }
      t.references :applied_by_user, foreign_key: { to_table: :users }
      t.references :source_deleted_by_user, foreign_key: { to_table: :users }
      t.string :document_kind, null: false
      t.string :status, null: false, default: "uploaded"
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false, default: 0
      t.string :checksum_sha256
      t.string :s3_key
      t.date :document_date
      t.date :period_start_on
      t.date :period_end_on
      t.text :extracted_summary
      t.text :extraction_error
      t.datetime :processed_at
      t.datetime :applied_at
      t.datetime :source_deleted_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :financial_document_imports, [ :household_id, :created_at ]
    add_index :financial_document_imports, [ :household_id, :status ]
    add_index :financial_document_imports, [ :household_id, :document_kind ]
    add_index :financial_document_imports, :s3_key
    add_check_constraint :financial_document_imports, "byte_size >= 0", name: "financial_document_imports_byte_size_non_negative"
  end
end
