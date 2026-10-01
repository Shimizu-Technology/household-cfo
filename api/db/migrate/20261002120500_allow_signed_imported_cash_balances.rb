class AllowSignedImportedCashBalances < ActiveRecord::Migration[8.0]
  def up
    if check_constraint_exists?(:financial_document_import_items, name: "financial_doc_items_balance_cents_non_negative")
      remove_check_constraint :financial_document_import_items, name: "financial_doc_items_balance_cents_non_negative"
    end
    return if check_constraint_exists?(:financial_document_import_items, name: "financial_doc_items_balance_cents_valid")

    add_check_constraint :financial_document_import_items,
      "balance_cents IS NULL OR balance_cents >= 0 OR (target_type = 'account' AND account_type IN ('checking', 'savings'))",
      name: "financial_doc_items_balance_cents_valid"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Negative imported checking and savings balances cannot be represented by the former constraint"
  end
end
