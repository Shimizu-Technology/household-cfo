class CreateFinancialSourceAccounting < ActiveRecord::Migration[8.1]
  def change
    create_table :financial_extraction_revisions do |t|
      t.references :household, null: false, foreign_key: true
      t.references :financial_document_import, foreign_key: { on_delete: :nullify }
      t.references :financial_document_import_attempt, foreign_key: { on_delete: :nullify }, index: { unique: true, name: "index_extraction_revisions_unique_attempt" }
      t.string :contract_version, null: false
      t.string :payload_digest, null: false
      t.string :source_document_identity, null: false
      t.integer :revision_number, null: false
      t.jsonb :coverage, null: false, default: {}
      t.jsonb :reconciliation, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :financial_extraction_revisions, [ :financial_document_import_id, :revision_number ], unique: true, name: "index_extraction_revisions_import_number"
    add_index :financial_extraction_revisions, [ :id, :household_id ], unique: true, name: "index_extraction_revisions_household_identity"
    create_table :financial_source_accounts do |t|
      t.references :household, null: false, foreign_key: true
      t.references :financial_extraction_revision, null: false, foreign_key: true, index: { name: "index_source_accounts_revision" }
      t.string :source_key, null: false
      t.string :account_basis, null: false, default: "unknown"
      t.date :period_start_on
      t.date :period_end_on
      t.bigint :opening_balance_cents
      t.bigint :closing_balance_cents
      t.bigint :printed_debit_cents
      t.bigint :printed_credit_cents
      t.integer :printed_row_count
      t.jsonb :limitations, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :financial_source_accounts, [ :financial_extraction_revision_id, :source_key ], unique: true, name: "index_source_accounts_revision_key"
    add_index :financial_source_accounts, [ :id, :financial_extraction_revision_id, :household_id ], unique: true, name: "index_source_accounts_scoped_identity"
    add_index :financial_source_accounts, [ :id, :household_id ], unique: true, name: "index_source_accounts_household_identity"
    add_foreign_key :financial_source_accounts, :financial_extraction_revisions, column: [ :financial_extraction_revision_id, :household_id ], primary_key: [ :id, :household_id ], name: "source_accounts_revision_household_fk"
    add_check_constraint :financial_source_accounts, "account_basis IN ('asset', 'liability', 'unknown')", name: "source_account_basis_valid"
    create_table :financial_source_events do |t|
      t.references :household, null: false, foreign_key: true
      t.references :financial_extraction_revision, null: false, foreign_key: true, index: { name: "index_source_events_revision" }
      t.references :financial_source_account, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :row_identity, null: false
      t.string :row_kind, null: false
      t.string :event_type, null: false
      t.bigint :signed_amount_cents
      t.bigint :expense_amount_cents
      t.date :posted_on
      t.date :authorized_on
      t.jsonb :locator, null: false, default: {}
      t.jsonb :funding_components, null: false, default: []
      t.jsonb :limitations, null: false, default: []
      t.datetime :created_at, null: false
    end
    add_index :financial_source_events, [ :financial_extraction_revision_id, :row_identity ], unique: true, name: "index_source_events_revision_row"
    add_index :financial_source_events, [ :financial_extraction_revision_id, :position ], unique: true, name: "index_source_events_revision_position"
    add_index :financial_source_events, [ :id, :household_id ], unique: true, name: "index_source_events_household_identity"
    add_foreign_key :financial_source_events, :financial_source_accounts, column: [ :financial_source_account_id, :financial_extraction_revision_id, :household_id ], primary_key: [ :id, :financial_extraction_revision_id, :household_id ], name: "source_events_account_revision_household_fk"
    add_check_constraint :financial_source_events, "row_kind IN ('posted', 'informational', 'unresolved')", name: "source_event_kind_valid"
    add_check_constraint :financial_source_events, "event_type IN ('purchase', 'fee', 'refund', 'income', 'transfer', 'debt_payment', 'cash_withdrawal', 'interest', 'adjustment', 'unknown')", name: "source_event_type_valid"
    add_check_constraint :financial_source_events, "expense_amount_cents IS NULL OR expense_amount_cents > 0", name: "source_event_expense_positive"
    add_check_constraint :financial_source_events, "expense_amount_cents IS NULL OR (row_kind = 'posted' AND event_type IN ('purchase', 'fee', 'interest') AND signed_amount_cents < 0 AND posted_on IS NOT NULL)", name: "source_event_expense_eligible"
    create_table :financial_source_evidences do |t|
      t.references :household, null: false, foreign_key: true
      t.references :financial_source_account, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :financial_source_event, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :financial_source_evidences, "num_nonnulls(financial_source_account_id, financial_source_event_id) = 1", name: "source_evidence_one_subject"
    add_foreign_key :financial_source_evidences, :financial_source_accounts, column: [ :financial_source_account_id, :household_id ], primary_key: [ :id, :household_id ], on_delete: :cascade, name: "source_evidence_account_household_fk"
    add_foreign_key :financial_source_evidences, :financial_source_events, column: [ :financial_source_event_id, :household_id ], primary_key: [ :id, :household_id ], on_delete: :cascade, name: "source_evidence_event_household_fk"
    add_reference :transaction_drafts, :financial_source_event, foreign_key: { on_delete: :nullify }
    add_reference :household_transactions, :financial_source_event, foreign_key: { on_delete: :nullify }
    add_foreign_key :transaction_drafts, :financial_source_events, column: [ :financial_source_event_id, :household_id ], primary_key: [ :id, :household_id ], name: "source_drafts_event_household_fk"
    add_foreign_key :household_transactions, :financial_source_events, column: [ :financial_source_event_id, :household_id ], primary_key: [ :id, :household_id ], name: "source_transactions_event_household_fk"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION source_accounting_facts_immutable() RETURNS trigger AS $$
          BEGIN
            IF TG_TABLE_NAME = 'financial_extraction_revisions' THEN
              IF (to_jsonb(NEW) - 'financial_document_import_id' - 'financial_document_import_attempt_id') <> (to_jsonb(OLD) - 'financial_document_import_id' - 'financial_document_import_attempt_id') OR
                 (NEW.financial_document_import_id IS DISTINCT FROM OLD.financial_document_import_id AND NEW.financial_document_import_id IS NOT NULL) OR
                 (NEW.financial_document_import_attempt_id IS DISTINCT FROM OLD.financial_document_import_attempt_id AND NEW.financial_document_import_attempt_id IS NOT NULL) THEN
                RAISE EXCEPTION 'Source accounting facts are immutable; append a revision';
              END IF;
            ELSIF to_jsonb(NEW) <> to_jsonb(OLD) THEN
              RAISE EXCEPTION 'Source accounting facts are immutable; append a revision';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
        SQL
        %w[financial_extraction_revisions financial_source_accounts financial_source_events].each do |table|
          execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_accounting_facts_immutable()"
        end
      end
      direction.down do
        %w[financial_extraction_revisions financial_source_accounts financial_source_events].each do |table|
          execute "DROP TRIGGER IF EXISTS #{table}_immutable ON #{table}"
        end
        execute "DROP FUNCTION IF EXISTS source_accounting_facts_immutable()"
      end
    end
  end
end
