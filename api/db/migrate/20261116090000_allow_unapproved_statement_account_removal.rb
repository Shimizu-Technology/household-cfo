class AllowUnapprovedStatementAccountRemoval < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE FUNCTION statement_account_answers_removable(document_id bigint) RETURNS boolean LANGUAGE sql AS $$
        SELECT EXISTS (SELECT 1 FROM financial_document_imports d WHERE d.id = document_id AND d.document_kind = 'statement')
          AND NOT EXISTS (SELECT 1 FROM financial_document_import_items WHERE financial_document_import_id = document_id AND applied_at IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM transaction_drafts WHERE financial_document_import_id = document_id AND status IN ('confirmed', 'corrected', 'matched'))
          AND NOT EXISTS (SELECT 1 FROM household_transactions WHERE source_import_id = document_id AND status IN ('confirmed', 'reconciled'))
          AND NOT EXISTS (SELECT 1 FROM financial_extraction_revisions r WHERE r.financial_document_import_id = document_id AND (
            EXISTS (SELECT 1 FROM source_revision_approvals WHERE financial_extraction_revision_id = r.id)
            OR EXISTS (SELECT 1 FROM financial_source_events e WHERE e.financial_extraction_revision_id = r.id AND (
              EXISTS (SELECT 1 FROM source_review_heads WHERE financial_source_event_id = e.id AND approved_version_id IS NOT NULL)
              OR EXISTS (SELECT 1 FROM household_transactions WHERE financial_source_event_id = e.id AND status IN ('confirmed', 'reconciled'))
              OR EXISTS (SELECT 1 FROM savings_evidence_capacities WHERE financial_source_event_id = e.id)))))
      $$;
      CREATE FUNCTION unapproved_statement_account_delete() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE document_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'source_tracked_accounts' THEN
          IF OLD.account_id IS NULL AND NOT EXISTS (SELECT 1 FROM source_account_identity_versions WHERE source_tracked_account_id = OLD.id) THEN RETURN OLD; END IF;
        ELSE
          IF TG_TABLE_NAME = 'source_account_review_heads' THEN
            SELECT r.financial_document_import_id INTO document_id FROM financial_source_accounts a JOIN financial_extraction_revisions r ON r.id = a.financial_extraction_revision_id WHERE a.id = OLD.financial_source_account_id;
          ELSE
            SELECT r.financial_document_import_id INTO document_id FROM source_account_review_heads h JOIN financial_source_accounts a ON a.id = h.financial_source_account_id JOIN financial_extraction_revisions r ON r.id = a.financial_extraction_revision_id WHERE h.id = OLD.source_account_review_head_id;
          END IF;
          IF statement_account_answers_removable(document_id) THEN RETURN OLD; END IF;
        END IF;
        RAISE EXCEPTION 'Approved source facts cannot be deleted';
      END; $$;
    SQL
    %w[source_account_identity_versions source_tracked_accounts].each do |table|
      execute "DROP TRIGGER #{table}_immutable ON #{table}"
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()"
      execute "CREATE TRIGGER #{table}_unapproved_delete BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION unapproved_statement_account_delete()"
    end
    execute "DROP TRIGGER source_account_review_heads_scope_immutable ON source_account_review_heads"
    execute "CREATE TRIGGER source_account_review_heads_scope_immutable BEFORE UPDATE ON source_account_review_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable()"
    execute "CREATE TRIGGER source_account_review_heads_unapproved_delete BEFORE DELETE ON source_account_review_heads FOR EACH ROW EXECUTE FUNCTION unapproved_statement_account_delete()"
  end

  def down
    %w[source_account_identity_versions source_tracked_accounts].each do |table|
      execute "DROP TRIGGER #{table}_unapproved_delete ON #{table}"
      execute "DROP TRIGGER #{table}_immutable ON #{table}"
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()"
    end
    execute "DROP TRIGGER source_account_review_heads_unapproved_delete ON source_account_review_heads"
    execute "DROP TRIGGER source_account_review_heads_scope_immutable ON source_account_review_heads"
    execute "CREATE TRIGGER source_account_review_heads_scope_immutable BEFORE UPDATE OR DELETE ON source_account_review_heads FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable()"
    execute "DROP FUNCTION unapproved_statement_account_delete()"
    execute "DROP FUNCTION statement_account_answers_removable(bigint)"
  end
end
