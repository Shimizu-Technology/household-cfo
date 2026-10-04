class CreateFinancialDocumentSourceCleanups < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_document_source_cleanups do |t|
      t.references :financial_document_import, foreign_key: { on_delete: :nullify }, index: { name: "idx_document_cleanup_import" }
      t.references :household, foreign_key: { on_delete: :nullify }
      t.references :requested_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :s3_key, limit: 1024
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :next_attempt_at, null: false
      t.datetime :completed_at
      t.string :error_code
      t.timestamps
    end
    add_index :financial_document_source_cleanups, :s3_key, unique: true, name: "idx_document_cleanup_key"
    add_index :financial_document_source_cleanups, [ :status, :next_attempt_at ], name: "idx_document_cleanup_due"
    add_check_constraint :financial_document_source_cleanups, "attempts >= 0", name: "document_cleanup_attempts_nonnegative"
    add_check_constraint :financial_document_source_cleanups, "status IN ('pending', 'processing', 'failed', 'completed')", name: "document_cleanup_status_valid"
  end
end
