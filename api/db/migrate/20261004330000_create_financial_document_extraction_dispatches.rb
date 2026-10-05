class CreateFinancialDocumentExtractionDispatches < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_document_extraction_dispatches do |t|
      t.references :financial_document_import, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.bigint :generation, null: false, default: 1
      t.string :source_fingerprint, null: false
      t.datetime :next_attempt_at, null: false
      t.datetime :lease_expires_at
      t.string :lease_token
      t.integer :enqueue_attempts, null: false, default: 0
      t.string :error_code
      t.timestamps
    end
    add_index :financial_document_extraction_dispatches, [ :status, :next_attempt_at ], name: "index_extraction_dispatches_recovery"
    add_check_constraint :financial_document_extraction_dispatches, "generation > 0 AND enqueue_attempts >= 0", name: "extraction_dispatch_counters"
    add_check_constraint :financial_document_extraction_dispatches, "status NOT IN ('enqueued', 'processing') OR lease_expires_at IS NOT NULL", name: "extraction_dispatch_active_lease"
    add_check_constraint :financial_document_extraction_dispatches, "status IN ('pending', 'enqueued', 'processing', 'completed', 'cancelled')", name: "extraction_dispatch_status"
  end
end
