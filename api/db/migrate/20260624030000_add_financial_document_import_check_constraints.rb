class AddFinancialDocumentImportCheckConstraints < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :financial_document_imports,
      "document_kind IN ('spreadsheet', 'statement', 'pay_stub', 'receipt', 'other')",
      name: "financial_document_imports_document_kind_valid"
    add_check_constraint :financial_document_imports,
      "status IN ('uploaded', 'processing', 'needs_review', 'applied', 'partially_applied', 'failed', 'source_deleted')",
      name: "financial_document_imports_status_valid"

    add_check_constraint :financial_document_import_items,
      "target_type IN ('income_source', 'expense_item', 'account', 'debt', 'goal', 'profile_note')",
      name: "financial_document_import_items_target_type_valid"
    add_check_constraint :financial_document_import_items,
      "confidence IS NULL OR confidence IN ('high', 'medium', 'low')",
      name: "financial_document_import_items_confidence_valid"

    add_check_constraint :financial_document_import_attempts,
      "status IN ('processing', 'succeeded', 'failed')",
      name: "financial_document_import_attempts_status_valid"
    add_check_constraint :financial_document_import_attempts,
      "status = 'processing' OR completed_at IS NOT NULL",
      name: "financial_document_import_attempts_completed_at_required_when_terminal"
  end
end
