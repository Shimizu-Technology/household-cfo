class CreateSourceReviewDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :source_tracked_accounts do |t|
      household(t)
      t.references :account, foreign_key: { on_delete: :nullify }
      t.string :label, null: false
      t.string :account_basis, null: false
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    create_table :source_account_review_heads do |t|
      household(t)
      t.references :financial_source_account, null: false, foreign_key: true, index: { unique: true }
      t.bigint :approved_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :source_account_identity_versions do |t|
      household(t)
      t.references :source_account_review_head, null: false, foreign_key: true
      t.references :source_tracked_account, null: false, foreign_key: true
      approved_fields(t)
      t.jsonb :statement_facts, null: false, default: {}
    end
    create_table :source_review_heads do |t|
      household(t)
      t.references :financial_source_event, null: false, foreign_key: true, index: { unique: true }
      t.bigint :approved_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :source_review_drafts do |t|
      household(t)
      t.references :source_review_head, null: false, foreign_key: true
      t.references :staged_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :base_version_id
      t.integer :base_head_lock_version, null: false
      t.jsonb :facts, null: false
      t.jsonb :projection, null: false, default: {}
      t.text :reason, null: false
      t.string :digest, null: false
      t.string :status, null: false, default: "pending"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :source_review_drafts, :source_review_head_id, unique: true, where: "status = 'pending'", name: "source_one_pending_draft"
    create_table :source_review_versions do |t|
      household(t)
      t.references :source_review_head, null: false, foreign_key: true
      t.references :source_account_identity_version, null: false, foreign_key: true
      t.references :budget_category, foreign_key: true
      t.bigint :matched_version_id
      approved_fields(t)
      t.string :disposition, null: false
      t.string :event_type, null: false
      t.bigint :signed_amount_cents
      t.bigint :purchase_amount_cents
      t.date :posted_on
      t.date :authorized_on
      t.string :merchant
      t.string :external_reference
      t.string :source_artifact_digest
      t.jsonb :category_snapshot, null: false, default: {}
      t.jsonb :projection, null: false, default: {}
      t.string :overlap_disposition, null: false
    end
    create_table :source_revision_approvals do |t|
      household(t)
      t.references :financial_extraction_revision, null: false, foreign_key: true
      approved_fields(t)
      t.string :coverage_status, null: false
      t.jsonb :coverage_attestation, null: false
      t.jsonb :source_version_ids, null: false, default: []
      t.jsonb :account_version_ids, null: false, default: []
      t.jsonb :deficiencies, null: false, default: []
      t.jsonb :dependencies, null: false, default: {}
    end
    create_table :source_projection_revisions do |t|
      household(t)
      t.references :source_review_version, null: false, foreign_key: true, index: { unique: true }
      t.references :previous_transaction, foreign_key: { to_table: :household_transactions }
      t.references :replacement_transaction, foreign_key: { to_table: :household_transactions }
      t.string :action, null: false
      t.string :previous_snapshot_digest
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.text :reason, null: false
      t.string :digest, null: false
      t.datetime :created_at, null: false
    end
    create_table :source_economic_groups do |t|
      household(t)
      t.bigint :approved_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :source_economic_group_versions do |t|
      household(t)
      t.references :source_economic_group, null: false, foreign_key: true
      approved_fields(t)
      t.string :kind, null: false
    end
    create_table :source_economic_memberships do |t|
      household(t)
      t.references :source_economic_group_version, null: false, foreign_key: true
      t.references :source_review_version, null: false, foreign_key: true
      t.string :role, null: false
      t.bigint :allocation_cents, null: false
      t.datetime :created_at, null: false
    end
    add_index :source_economic_memberships, [ :source_economic_group_version_id, :source_review_version_id, :role ], unique: true, name: "source_economic_members_unique"

    tables = %i[source_tracked_accounts source_account_review_heads source_account_identity_versions source_review_heads source_review_drafts source_review_versions source_revision_approvals source_projection_revisions source_economic_groups source_economic_group_versions source_economic_memberships]
    tables.each { |table| add_index table, [ :id, :household_id ], unique: true, name: "#{table}_household_identity" }
    %i[accounts budget_categories household_transactions].each do |table|
      add_index table, [ :id, :household_id ], unique: true, name: "#{table}_source_review_household_identity"
    end
    scoped_fk :source_tracked_accounts, :accounts, :account_id, deferrable: :deferred
    scoped_fk :source_review_versions, :budget_categories, :budget_category_id
    scoped_fk :source_projection_revisions, :household_transactions, :previous_transaction_id
    scoped_fk :source_projection_revisions, :household_transactions, :replacement_transaction_id
    scoped_fk :source_account_review_heads, :financial_source_accounts, :financial_source_account_id
    scoped_fk :source_account_identity_versions, :source_account_review_heads, :source_account_review_head_id
    scoped_fk :source_account_identity_versions, :source_tracked_accounts, :source_tracked_account_id
    scoped_fk :source_review_heads, :financial_source_events, :financial_source_event_id
    scoped_fk :source_review_drafts, :source_review_heads, :source_review_head_id
    scoped_fk :source_review_versions, :source_review_heads, :source_review_head_id
    scoped_fk :source_review_versions, :source_account_identity_versions, :source_account_identity_version_id
    scoped_fk :source_review_versions, :source_review_versions, :matched_version_id
    scoped_fk :source_revision_approvals, :financial_extraction_revisions, :financial_extraction_revision_id
    scoped_fk :source_projection_revisions, :source_review_versions, :source_review_version_id
    scoped_fk :source_economic_group_versions, :source_economic_groups, :source_economic_group_id
    scoped_fk :source_economic_memberships, :source_economic_group_versions, :source_economic_group_version_id
    scoped_fk :source_economic_memberships, :source_review_versions, :source_review_version_id
    { source_account_review_heads: :source_account_identity_versions, source_review_heads: :source_review_versions, source_economic_groups: :source_economic_group_versions }.each do |head, versions|
      add_index versions, [ head.to_s.singularize.concat("_id"), :version_number ], unique: true, name: "#{versions}_sequence"
      head_column = "#{head.to_s.singularize}_id"
      add_index versions, [ :id, head_column, :household_id ], unique: true, name: "#{versions}_head_identity"
      add_foreign_key head, versions, column: [ :approved_version_id, :id, :household_id ], primary_key: [ :id, head_column, :household_id ], name: "#{head}_approved_head_scope"
      add_foreign_key versions, versions, column: [ :supersedes_id, head_column, :household_id ], primary_key: [ :id, head_column, :household_id ], name: "#{versions}_supersedes_head_scope"
      add_foreign_key versions, versions, column: :supersedes_id
    end
    add_index :source_revision_approvals, [ :financial_extraction_revision_id, :version_number ], unique: true, name: "source_revision_approval_sequence"
    add_foreign_key :source_revision_approvals, :source_revision_approvals, column: :supersedes_id
    add_foreign_key :source_review_drafts, :source_review_versions, column: [ :base_version_id, :source_review_head_id, :household_id ], primary_key: [ :id, :source_review_head_id, :household_id ], name: "source_review_drafts_base_head_scope"
    add_check_constraint :source_tracked_accounts, "account_basis IN ('asset', 'liability')", name: "source_tracked_basis"
    add_check_constraint :source_review_drafts, "status IN ('pending', 'approved', 'cancelled')", name: "source_review_draft_status"
    add_check_constraint :source_review_versions, "event_type IN ('purchase', 'fee', 'refund', 'income', 'transfer', 'debt_payment', 'cash_withdrawal', 'interest', 'adjustment', 'unknown')", name: "source_review_event_type"
    add_check_constraint :source_projection_revisions, "action IN ('create', 'replace', 'void')", name: "source_projection_action"
    add_check_constraint :source_review_versions, "disposition IN ('include', 'match', 'exclude', 'informational')", name: "source_review_disposition"
    add_check_constraint :source_review_versions, "disposition NOT IN ('include', 'match') OR (signed_amount_cents IS NOT NULL AND signed_amount_cents <> 0 AND posted_on IS NOT NULL AND event_type <> 'unknown')", name: "source_review_posted_facts"
    add_check_constraint :source_revision_approvals, "coverage_status IN ('complete', 'qualified')", name: "source_revision_coverage"
    add_check_constraint :source_economic_group_versions, "kind IN ('transfer', 'purchase_funding', 'refund')", name: "source_economic_kind"
    add_check_constraint :source_economic_memberships, "allocation_cents > 0", name: "source_economic_allocation"
    immutable = %w[source_tracked_accounts source_account_identity_versions source_review_versions source_revision_approvals source_projection_revisions source_economic_group_versions source_economic_memberships]
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION source_review_facts_immutable() RETURNS trigger AS $$
          BEGIN
            IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Approved source facts cannot be deleted'; END IF;
            IF TG_TABLE_NAME = 'source_tracked_accounts' AND NEW.account_id IS NULL AND
               (to_jsonb(NEW) - 'account_id') = (to_jsonb(OLD) - 'account_id') THEN RETURN NEW; END IF;
            IF to_jsonb(NEW) <> to_jsonb(OLD) THEN RAISE EXCEPTION 'Approved source facts are immutable; append a version'; END IF;
            RETURN NEW;
          END; $$ LANGUAGE plpgsql;
        SQL
        execute <<~SQL
          CREATE FUNCTION source_review_heads_scope_immutable() RETURNS trigger AS $$
          BEGIN
            IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Source review heads cannot be deleted'; END IF;
            IF (to_jsonb(NEW) - ARRAY['approved_version_id', 'lock_version', 'updated_at']) <>
               (to_jsonb(OLD) - ARRAY['approved_version_id', 'lock_version', 'updated_at']) THEN
              RAISE EXCEPTION 'Source review head identity is immutable';
            END IF;
            RETURN NEW;
          END; $$ LANGUAGE plpgsql;
        SQL
        %w[source_review_heads source_account_review_heads source_economic_groups].each do |table|
          execute "CREATE TRIGGER #{table}_scope_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_review_heads_scope_immutable()"
        end
        immutable.each { |table| execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()" }
      end
      direction.down do
        %w[source_review_heads source_account_review_heads source_economic_groups].each do |table|
          execute "DROP TRIGGER IF EXISTS #{table}_scope_immutable ON #{table}"
        end
        execute "DROP FUNCTION IF EXISTS source_review_heads_scope_immutable()"
        immutable.each { |table| execute "DROP TRIGGER IF EXISTS #{table}_immutable ON #{table}" }
        execute "DROP FUNCTION IF EXISTS source_review_facts_immutable()"
      end
    end
  end

  private

  def household(t)
    t.references :household, null: false, foreign_key: true
  end

  def approved_fields(t)
    t.integer :version_number, null: false
    t.bigint :supersedes_id
    t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
    t.text :reason, null: false
    t.string :digest, null: false
    t.datetime :created_at, null: false
  end

  def scoped_fk(from, to, column, **options)
    add_foreign_key from, to, column: [ column, :household_id ], primary_key: [ :id, :household_id ], name: "#{from}_#{column.to_s.delete_suffix('_id')}_scope".truncate(62, omission: ""), **options
  end
end
