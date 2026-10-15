# Counts worker claims of an extraction so a file that keeps killing its
# worker (out of memory, deploy, hostile input) stops being retried forever.
# Expand-only: a defaulted integer column is a metadata-only change.
class AddProcessingAttemptsToFinancialDocumentExtractionDispatches < ActiveRecord::Migration[8.1]
  def change
    add_column :financial_document_extraction_dispatches, :processing_attempts, :integer, default: 0, null: false
  end
end
