class AddDebtLifecycleAndTracking < ActiveRecord::Migration[8.0]
  def up
    change_column :debts, :balance_cents, :bigint, null: false, default: 0
    change_column :debts, :minimum_payment_cents, :bigint, null: false, default: 0
    add_column :debts, :active, :boolean, null: false, default: true
    add_column :debts, :archived_at, :datetime
    add_column :debts, :source_type, :string, null: false, default: "manual_ui"
    add_column :debts, :source_metadata, :jsonb, null: false, default: {}
    add_column :debts, :balance_known, :boolean, null: false, default: true
    add_column :debts, :minimum_payment_known, :boolean, null: false, default: true

    mark_legacy_setup_aggregates!
    backfill_document_import_provenance!

    ensure_no_case_insensitive_active_duplicates!
    remove_index :debts, name: "index_debts_on_household_debt_type_label"
    add_index :debts, "household_id, debt_type, lower(label)", unique: true,
      where: "active = TRUE", name: "index_active_debts_on_household_type_label"
    add_index :debts, [ :household_id, :active ], name: "index_debts_on_household_id_and_active"
    add_check_constraint :debts, "source_type IN ('manual_ui', 'mia', 'document_import', 'setup')", name: "debts_source_type_valid"
    add_check_constraint :debts, "(active = TRUE AND archived_at IS NULL) OR (active = FALSE AND archived_at IS NOT NULL)", name: "debts_archive_state_valid"

    add_column :household_profiles, :debt_tracking_mode, :string, null: false, default: "individual"
    add_column :household_profiles, :debt_summary_balance_cents, :bigint, null: false, default: 0
    add_column :household_profiles, :debt_summary_minimum_payment_cents, :bigint, null: false, default: 0
    add_column :household_profiles, :debt_summary_balance_known, :boolean, null: false, default: false
    add_column :household_profiles, :debt_summary_minimum_payment_known, :boolean, null: false, default: false
    add_check_constraint :household_profiles, "debt_tracking_mode IN ('summary', 'individual')", name: "household_profiles_debt_tracking_mode_valid"
    add_check_constraint :household_profiles, "debt_summary_balance_cents >= 0", name: "household_profiles_debt_summary_balance_non_negative"
    add_check_constraint :household_profiles, "debt_summary_minimum_payment_cents >= 0", name: "household_profiles_debt_summary_minimum_non_negative"

    reconcile_legacy_setup_debts!

    remove_check_constraint :mia_action_drafts, name: "mia_action_drafts_type_valid"
    add_check_constraint :mia_action_drafts,
      "draft_type IN ('budget_edit', 'household_setup', 'income_schedule', 'debt_plan')",
      name: "mia_action_drafts_type_valid"
    remove_check_constraint :mia_action_items, name: "mia_action_items_action_type_valid"
    add_check_constraint :mia_action_items,
      "action_type IN ('create_category', 'update_category', 'update_allocation', 'archive_category', 'restore_category', 'update_setup_value', 'upsert_income_schedule_entry', 'create_income_source', 'update_income_source', 'archive_income_source', 'restore_income_source', 'create_income_schedule_entry', 'update_income_schedule_entry', 'delete_income_schedule_entry', 'create_debt', 'update_debt', 'archive_debt', 'restore_debt', 'update_debt_tracking')",
      name: "mia_action_items_action_type_valid"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Debt archive history and case-insensitive active-name reuse cannot be represented by the former debt schema"
  end

  def ensure_no_case_insensitive_active_duplicates!
    duplicate_groups = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM (
        SELECT household_id, debt_type, lower(label)
        FROM debts
        WHERE active = TRUE
        GROUP BY household_id, debt_type, lower(label)
        HAVING COUNT(*) > 1
      ) duplicate_debts
    SQL
    return if duplicate_groups.zero?

    raise ActiveRecord::MigrationError,
      "Cannot enforce case-insensitive active debt names: #{duplicate_groups} household/type group(s) contain duplicate labels. Resolve them explicitly before retrying."
  end

  # Old import rows used zero as a storage placeholder when a statement only
  # supplied one of balance or payment. Derive knowledge from the complete
  # applied-item history so a later partial statement cannot erase a fact that
  # an earlier approved statement supplied.
  def backfill_document_import_provenance!
    execute <<~SQL.squish
      WITH known_facts AS (
        SELECT
          applied_record_id,
          BOOL_OR(balance_cents IS NOT NULL) AS balance_known,
          BOOL_OR(payment_cents IS NOT NULL) AS minimum_payment_known
        FROM financial_document_import_items
        WHERE applied_record_type = 'Debt' AND applied_record_id IS NOT NULL
        GROUP BY applied_record_id
      ), latest_lineage AS (
        SELECT DISTINCT ON (applied_record_id)
          id, financial_document_import_id, applied_record_id
        FROM financial_document_import_items
        WHERE applied_record_type = 'Debt' AND applied_record_id IS NOT NULL
        ORDER BY applied_record_id, applied_at DESC NULLS LAST, id DESC
      )
      UPDATE debts
      SET source_type = CASE WHEN debts.source_type = 'setup' THEN 'setup' ELSE 'document_import' END,
          source_metadata = jsonb_build_object(
            'document_import_id', latest_lineage.financial_document_import_id,
            'document_import_item_id', latest_lineage.id
          ),
          balance_known = CASE WHEN debts.source_type = 'setup' THEN debts.balance_known OR known_facts.balance_known ELSE known_facts.balance_known END,
          minimum_payment_known = CASE WHEN debts.source_type = 'setup' THEN debts.minimum_payment_known OR known_facts.minimum_payment_known ELSE known_facts.minimum_payment_known END
      FROM latest_lineage
      INNER JOIN known_facts
        ON known_facts.applied_record_id = latest_lineage.applied_record_id
      WHERE debts.id = latest_lineage.applied_record_id
    SQL
  end

  def mark_legacy_setup_aggregates!
    execute <<~SQL.squish
      UPDATE debts debt
      SET source_type = 'setup',
          balance_known = household.confirmed_setup_fields @> '["credit_card_debt"]'::jsonb,
          minimum_payment_known = household.confirmed_setup_fields @> '["debt_payment"]'::jsonb
      FROM households household
      WHERE debt.household_id = household.id
        AND debt.debt_type = 'credit_card'
        AND lower(debt.label) = 'credit card debt'
        AND debt.source_type = 'manual_ui'
        AND (
          household.confirmed_setup_fields @> '["credit_card_debt"]'::jsonb
          OR household.confirmed_setup_fields @> '["debt_payment"]'::jsonb
        )
    SQL
  end

  # The former setup form stored one aggregate credit-card row named
  # "Credit card debt". A later statement import could add detailed cards next
  # to it, making the old read path count both. Preserve every row, archive the
  # overlapping setup aggregate, and keep its approved total as the canonical
  # summary. Non-credit-card debts are added because they were never part of
  # that setup aggregate. The household can explicitly switch to the preserved
  # active individual records after reviewing them.
  def reconcile_legacy_setup_debts!
    mark_legacy_setup_aggregates!

    execute <<~SQL.squish
      UPDATE household_profiles profile
      SET debt_tracking_mode = 'summary',
          debt_summary_balance_cents = 0,
          debt_summary_minimum_payment_cents = 0,
          debt_summary_balance_known = household.confirmed_setup_fields @> '["credit_card_debt"]'::jsonb,
          debt_summary_minimum_payment_known = household.confirmed_setup_fields @> '["debt_payment"]'::jsonb,
          updated_at = CURRENT_TIMESTAMP
      FROM households household
      WHERE household.id = profile.household_id
        AND (
          household.confirmed_setup_fields @> '["credit_card_debt"]'::jsonb
          OR household.confirmed_setup_fields @> '["debt_payment"]'::jsonb
        )
        AND NOT EXISTS (
          SELECT 1 FROM debts debt
          WHERE debt.household_id = household.id AND debt.active = TRUE
        )
    SQL

    execute <<~SQL.squish
      WITH overlapping AS (
        SELECT
          aggregate.id AS aggregate_id,
          aggregate.household_id,
          aggregate.balance_cents + COALESCE(SUM(other.balance_cents) FILTER (WHERE other.debt_type <> 'credit_card'), 0) AS summary_balance_cents,
          aggregate.minimum_payment_cents + COALESCE(SUM(other.minimum_payment_cents) FILTER (WHERE other.debt_type <> 'credit_card'), 0) AS summary_minimum_payment_cents,
          aggregate.balance_known AND COALESCE(BOOL_AND(other.balance_known) FILTER (WHERE other.debt_type <> 'credit_card'), TRUE) AS summary_balance_known,
          aggregate.minimum_payment_known AND COALESCE(BOOL_AND(other.minimum_payment_known) FILTER (WHERE other.debt_type <> 'credit_card'), TRUE) AS summary_minimum_payment_known
        FROM debts aggregate
        LEFT JOIN debts other
          ON other.household_id = aggregate.household_id
          AND other.id <> aggregate.id
          AND other.active = TRUE
        WHERE aggregate.active = TRUE
          AND aggregate.source_type = 'setup'
          AND aggregate.debt_type = 'credit_card'
          AND lower(aggregate.label) = 'credit card debt'
          AND EXISTS (
            SELECT 1
            FROM debts detailed
            WHERE detailed.household_id = aggregate.household_id
              AND detailed.id <> aggregate.id
              AND detailed.active = TRUE
              AND detailed.debt_type = 'credit_card'
          )
        GROUP BY aggregate.id, aggregate.household_id, aggregate.balance_cents, aggregate.minimum_payment_cents
      ), updated_profiles AS (
        UPDATE household_profiles profile
        SET debt_tracking_mode = 'summary',
            debt_summary_balance_cents = overlapping.summary_balance_cents,
            debt_summary_minimum_payment_cents = overlapping.summary_minimum_payment_cents,
          debt_summary_balance_known = overlapping.summary_balance_known,
          debt_summary_minimum_payment_known = overlapping.summary_minimum_payment_known,
            updated_at = CURRENT_TIMESTAMP
        FROM overlapping
        WHERE profile.household_id = overlapping.household_id
        RETURNING overlapping.aggregate_id
      )
      UPDATE debts
      SET active = FALSE,
          archived_at = CURRENT_TIMESTAMP,
          updated_at = CURRENT_TIMESTAMP
      WHERE id IN (SELECT aggregate_id FROM updated_profiles)
    SQL
  end
end
