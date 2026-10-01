class AddAccountLifecycleAndPlaidLinks < ActiveRecord::Migration[8.0]
  def up
    change_column :accounts, :balance_cents, :bigint, null: false, default: 0
    add_column :accounts, :active, :boolean, null: false, default: true
    add_column :accounts, :archived_at, :datetime
    add_column :accounts, :balance_known, :boolean, null: false, default: true
    add_column :accounts, :balance_as_of_on, :date
    add_column :accounts, :source_type, :string, null: false, default: "manual_ui"
    add_column :accounts, :source_metadata, :jsonb, null: false, default: {}
    add_reference :accounts, :plaid_account, null: true, index: false,
      foreign_key: { to_table: :plaid_accounts, on_delete: :nullify }
    add_column :accounts, :plaid_reconciled_at, :datetime

    backfill_account_provenance!
    ensure_no_case_insensitive_active_duplicates!

    remove_index :accounts, name: "index_accounts_on_household_account_type_label"
    remove_check_constraint :accounts, name: "accounts_balance_cents_non_negative"
    add_index :accounts, "household_id, account_type, lower(label)", unique: true,
      where: "active = TRUE", name: "index_active_accounts_on_household_type_label"
    add_index :accounts, [ :household_id, :active ], name: "index_accounts_on_household_id_and_active"
    add_index :accounts, :plaid_account_id, unique: true,
      where: "plaid_account_id IS NOT NULL", name: "index_accounts_on_unique_plaid_account"
    add_check_constraint :accounts,
      "(active = TRUE AND archived_at IS NULL) OR (active = FALSE AND archived_at IS NOT NULL)",
      name: "accounts_archive_state_valid"
    add_check_constraint :accounts,
      "balance_known = TRUE OR (balance_cents = 0 AND balance_as_of_on IS NULL)",
      name: "accounts_unknown_balance_zero_without_date"
    add_check_constraint :accounts,
      "account_type IN ('checking', 'savings') OR balance_cents >= 0",
      name: "accounts_balance_signed_only_for_cash"
    add_check_constraint :accounts,
      "source_type IN ('manual_ui', 'mia', 'document_import', 'setup', 'plaid')",
      name: "accounts_source_type_valid"
    add_check_constraint :accounts, "jsonb_typeof(source_metadata) = 'object'",
      name: "accounts_source_metadata_object"

    remove_check_constraint :financial_document_import_items,
      name: "financial_doc_items_balance_cents_non_negative"
    add_check_constraint :financial_document_import_items,
      "balance_cents IS NULL OR balance_cents >= 0 OR (target_type = 'account' AND account_type IN ('checking', 'savings'))",
      name: "financial_doc_items_balance_cents_valid"

    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule', 'debt_plan', 'asset_plan')",
      name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', 'update_setup_value', 'upsert_income_schedule_entry', 'create_income_source', 'update_income_source', 'archive_income_source', 'restore_income_source', 'create_income_schedule_entry', 'update_income_schedule_entry', 'delete_income_schedule_entry', 'create_debt', 'update_debt', 'archive_debt', 'restore_debt', 'update_debt_tracking', 'create_account', 'update_account', 'archive_account', 'restore_account', 'link_plaid_account', 'reconcile_plaid_account', 'unlink_plaid_account')",
      name: "mia_action_items_action_type_valid"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Account archive history, unknown balances, and Plaid reconciliation links cannot be represented by the former account schema"
  end

  def ensure_no_case_insensitive_active_duplicates!
    duplicate_groups = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM (
        SELECT household_id, account_type, lower(label)
        FROM accounts WHERE active = TRUE
        GROUP BY household_id, account_type, lower(label)
        HAVING COUNT(*) > 1
      ) duplicate_accounts
    SQL
    return if duplicate_groups.zero?

    raise ActiveRecord::MigrationError,
      "Cannot enforce case-insensitive active account names: #{duplicate_groups} household/type group(s) contain duplicate labels. Resolve them explicitly before retrying."
  end

  def backfill_account_provenance!
    execute <<~SQL.squish
      UPDATE accounts account
      SET source_type = 'setup',
          balance_known = CASE
            WHEN account.balance_cents <> 0 THEN TRUE
            ELSE FALSE
          END,
          balance_as_of_on = NULL,
          source_metadata = jsonb_build_object('legacy_setup_field',
            CASE WHEN account.account_type = 'emergency_fund' THEN 'emergency_fund' ELSE 'other_assets' END)
      FROM households household
      WHERE account.household_id = household.id
        AND ((account.account_type = 'emergency_fund' AND lower(account.label) = 'emergency fund')
          OR (account.account_type = 'other' AND lower(account.label) = 'other assets'))
        AND (household.confirmed_setup_fields ?
          (CASE WHEN account.account_type = 'emergency_fund' THEN 'emergency_fund' ELSE 'other_assets' END))
    SQL

    execute <<~SQL.squish
      WITH latest_lineage AS (
        SELECT DISTINCT ON (applied_record_id)
          id, financial_document_import_id, applied_record_id
        FROM financial_document_import_items
        WHERE applied_record_type = 'Account' AND applied_record_id IS NOT NULL
        ORDER BY applied_record_id, applied_at DESC NULLS LAST, id DESC
      )
      UPDATE accounts
      SET source_type = 'document_import',
          balance_known = TRUE,
          source_metadata = jsonb_build_object(
            'document_import_id', latest_lineage.financial_document_import_id,
            'document_import_item_id', latest_lineage.id
          )
      FROM latest_lineage
      WHERE accounts.id = latest_lineage.applied_record_id
    SQL
  end
end
