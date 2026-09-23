class AddAprToDocumentImportItems < ActiveRecord::Migration[8.1]
  def change
    add_column :financial_document_import_items, :interest_rate_percent, :decimal, precision: 6, scale: 2
    add_check_constraint :financial_document_import_items,
      "interest_rate_percent IS NULL OR (interest_rate_percent >= 0 AND interest_rate_percent <= 999.99)",
      name: "financial_doc_items_apr_valid"
  end
end
