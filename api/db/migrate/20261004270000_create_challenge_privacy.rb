class CreateChallengePrivacy < ActiveRecord::Migration[8.1]
  def up
    create_table :challenge_privacy_grants do |t|
      scope_columns(t)
      t.references :recipient_user, foreign_key: { to_table: :users }
      t.string :kind, null: false
      t.boolean :granted, null: false, default: false
      t.jsonb :selected_records, null: false, default: []
      t.datetime :expires_at
      t.string :policy_version, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    execute "CREATE UNIQUE INDEX challenge_privacy_grant_identity ON challenge_privacy_grants (savings_enrollment_id, kind, COALESCE(recipient_user_id, 0))"
    add_check_constraint :challenge_privacy_grants, "kind IN ('coach_summary','selected_details','sponsor_aggregate') AND ((kind = 'sponsor_aggregate' AND recipient_user_id IS NULL) OR (kind <> 'sponsor_aggregate' AND recipient_user_id IS NOT NULL))", name: "challenge_privacy_grant_kind"

    create_table :challenge_support_tickets do |t|
      scope_columns(t)
      t.references :recipient_user, null: false, foreign_key: { to_table: :users }
      t.string :issue_kind, null: false
      t.string :message, limit: 500, null: false
      t.jsonb :selected_records, null: false, default: []
      t.string :status, null: false, default: "open"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :challenge_support_tickets, "status IN ('open','triaged','resolved')", name: "challenge_support_status"
    create_table :challenge_support_accesses do |t|
      scope_columns(t)
      t.references :challenge_support_ticket, null: false, foreign_key: true
      t.references :recipient_user, null: false, foreign_key: { to_table: :users }
      t.jsonb :selected_records, null: false, default: []
      t.string :reason, limit: 500, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :challenge_privacy_events do |t|
      scope_columns(t)
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.jsonb :approved_values, null: false, default: {}
      t.datetime :created_at, null: false
    end
    create_table :challenge_privacy_reads do |t|
      scope_columns(t)
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :purpose, null: false
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.datetime :created_at, null: false
    end
    create_table :financial_source_uses do |t|
      scope_columns(t)
      t.references :financial_document_import, foreign_key: { on_delete: :nullify }
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string :disclosure_version, null: false
      t.datetime :authorized_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :financial_source_uses, [ :financial_document_import_id, :savings_enrollment_id ], unique: true, name: "financial_source_use_identity"
    create_table :challenge_sponsor_exports do |t|
      t.references :cohort, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :checkpoint_day, null: false
      t.string :policy_version, null: false
      t.date :resolved_cutoff_on, null: false
      t.jsonb :private_provenance, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.string :digest, null: false
      t.datetime :created_at, null: false
    end
    add_index :challenge_sponsor_exports, [ :cohort_id, :checkpoint_day, :policy_version ], unique: true, name: "challenge_sponsor_fixed_identity"
    add_check_constraint :challenge_sponsor_exports, "checkpoint_day IN (30,60,90)", name: "challenge_sponsor_day"
    %w[challenge_privacy_events challenge_privacy_reads challenge_sponsor_exports].each do |table|
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()"
    end
    execute <<~SQL
      CREATE FUNCTION challenge_privacy_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE enrollment savings_enrollments;
      BEGIN
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
        IF NEW.household_id <> enrollment.household_id OR NEW.participant_user_id <> enrollment.user_id THEN
          RAISE EXCEPTION 'challenge privacy participant scope' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF TG_OP = 'UPDATE' AND (NEW.household_id, NEW.participant_user_id, NEW.savings_enrollment_id) IS DISTINCT FROM (OLD.household_id, OLD.participant_user_id, OLD.savings_enrollment_id) THEN
          RAISE EXCEPTION 'challenge privacy identity is immutable';
        END IF;
        IF TG_TABLE_NAME = 'challenge_privacy_grants' AND TG_OP = 'UPDATE' THEN
          IF (NEW.kind, NEW.recipient_user_id) IS DISTINCT FROM (OLD.kind, OLD.recipient_user_id) THEN RAISE EXCEPTION 'sharing recipient and purpose are immutable'; END IF;
        ELSIF TG_TABLE_NAME = 'challenge_support_tickets' AND TG_OP = 'UPDATE' THEN
          IF (NEW.recipient_user_id, NEW.issue_kind, NEW.message, NEW.selected_records) IS DISTINCT FROM (OLD.recipient_user_id, OLD.issue_kind, OLD.message, OLD.selected_records) THEN RAISE EXCEPTION 'approved support request is immutable'; END IF;
        ELSIF TG_TABLE_NAME = 'challenge_support_accesses' THEN
          IF NOT EXISTS (SELECT 1 FROM challenge_support_tickets t WHERE t.id = NEW.challenge_support_ticket_id AND t.savings_enrollment_id = NEW.savings_enrollment_id AND t.recipient_user_id = NEW.recipient_user_id) THEN RAISE EXCEPTION 'support ticket scope mismatch'; END IF;
          IF TG_OP = 'UPDATE' THEN
            IF (NEW.challenge_support_ticket_id, NEW.recipient_user_id, NEW.selected_records, NEW.reason, NEW.expires_at) IS DISTINCT FROM (OLD.challenge_support_ticket_id, OLD.recipient_user_id, OLD.selected_records, OLD.reason, OLD.expires_at) THEN RAISE EXCEPTION 'approved support scope is immutable'; END IF;
            IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN RAISE EXCEPTION 'support access cannot be revived'; END IF;
          END IF;
        ELSIF TG_TABLE_NAME = 'financial_source_uses' AND TG_OP = 'UPDATE' THEN
          IF NEW.financial_document_import_id IS DISTINCT FROM OLD.financial_document_import_id AND NEW.financial_document_import_id IS NOT NULL THEN RAISE EXCEPTION 'source use identity is immutable'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
    SQL
    scoped_tables.each do |table|
      execute "CREATE TRIGGER #{table}_scope BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard()"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Privacy approvals, support audit and fixed exports must be preserved" if (scoped_tables + [ "challenge_sponsor_exports" ]).any? { |table| select_value("SELECT EXISTS (SELECT 1 FROM #{table})") }
    (scoped_tables.reverse + [ "challenge_sponsor_exports" ]).each { |table| drop_table table }
    execute "DROP FUNCTION challenge_privacy_scope_guard()"
  end

  private

  def scoped_tables = %w[challenge_privacy_grants challenge_support_tickets challenge_support_accesses challenge_privacy_events challenge_privacy_reads financial_source_uses]
  def scope_columns(table)
    table.references :household, null: false, foreign_key: true
    table.references :savings_enrollment, null: false, foreign_key: true
    table.references :participant_user, null: false, foreign_key: { to_table: :users }
  end
end
