class CreateOptionalSavingsDebt < ActiveRecord::Migration[8.1]
  def up
    create_table :savings_debt_cards do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :source_tracked_account, foreign_key: true
      t.bigint :current_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :savings_debt_cards, [ :savings_enrollment_id, :source_tracked_account_id ], unique: true, where: "source_tracked_account_id IS NOT NULL", name: "savings_debt_canonical_account_once"
    create_table :savings_debt_versions do |t|
      t.references :savings_debt_card, null: false, foreign_key: true
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_version_id
      t.integer :version_number, null: false
      source_columns(t)
      t.jsonb :terms, null: false
      t.string :digest, null: false
      t.text :reason, null: false, default: ""
      t.datetime :approved_at, null: false
      t.timestamps
    end
    add_index :savings_debt_versions, [ :savings_debt_card_id, :version_number ], unique: true, name: "savings_debt_version_sequence"
    add_index :savings_debt_versions, [ :id, :savings_debt_card_id ], unique: true, name: "savings_debt_version_head_identity"
    execute "ALTER TABLE savings_debt_cards ADD CONSTRAINT savings_debt_current_scope FOREIGN KEY (current_version_id,id) REFERENCES savings_debt_versions(id,savings_debt_card_id)"
    execute "ALTER TABLE savings_debt_versions ADD CONSTRAINT savings_debt_previous_scope FOREIGN KEY (previous_version_id,savings_debt_card_id) REFERENCES savings_debt_versions(id,savings_debt_card_id)"
    create_table :savings_debt_drafts do |t|
      t.references :savings_debt_card, null: false, foreign_key: true
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :base_version_id
      t.integer :base_head_lock_version, null: false
      t.bigint :approved_version_id
      source_columns(t)
      t.jsonb :terms, null: false
      t.text :reason, null: false, default: ""
      t.string :status, null: false, default: "pending"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    %w[base approved].each do |prefix|
      execute "ALTER TABLE savings_debt_drafts ADD CONSTRAINT savings_debt_#{prefix}_scope FOREIGN KEY (#{prefix}_version_id,savings_debt_card_id) REFERENCES savings_debt_versions(id,savings_debt_card_id)"
    end
    install_guards
    %i[savings_debt_versions savings_debt_drafts].each do |table|
      add_check_constraint table, "savings_debt_terms_valid(terms)", name: "#{table}_terms_valid"
      add_check_constraint table, "length(reason) <= 500", name: "#{table}_reason_length"
      add_check_constraint table, "(source_tracked_account_id IS NULL AND source_account_identity_version_id IS NULL AND source_revision_approval_id IS NULL AND source_fingerprint IS NULL AND source_snapshot = '{}'::jsonb) OR (source_tracked_account_id IS NOT NULL AND source_account_identity_version_id IS NOT NULL AND source_revision_approval_id IS NOT NULL AND source_fingerprint ~ '^[0-9a-f]{64}$' AND jsonb_typeof(source_snapshot) = 'object')", name: "#{table}_mapping_complete"
    end
    add_check_constraint :savings_debt_versions, "version_number > 0 AND digest ~ '^[0-9a-f]{64}$'", name: "savings_debt_approved_digest"
    add_check_constraint :savings_debt_drafts, "base_head_lock_version >= 0 AND ((status='pending' AND approved_version_id IS NULL) OR (status='approved' AND approved_version_id IS NOT NULL))", name: "savings_debt_draft_state"
  end

  def down
    execute "LOCK TABLE savings_debt_cards,savings_debt_drafts,savings_debt_versions IN ACCESS EXCLUSIVE MODE"
    raise ActiveRecord::IrreversibleMigration, "Participant card review history must be retained" if select_value("SELECT EXISTS (SELECT 1 FROM savings_debt_cards UNION ALL SELECT 1 FROM savings_debt_drafts UNION ALL SELECT 1 FROM savings_debt_versions)")
    execute "DROP TABLE savings_debt_drafts,savings_debt_versions,savings_debt_cards CASCADE"
    execute "DROP FUNCTION savings_debt_scope_guard(), savings_debt_terms_valid(jsonb)"
  end

  private

  def source_columns(t)
    t.references :source_tracked_account, foreign_key: true
    t.references :source_account_identity_version, foreign_key: true
    t.references :source_revision_approval, foreign_key: true
    t.string :source_fingerprint
    t.jsonb :source_snapshot, null: false, default: {}
  end

  def install_guards
    execute <<~'SQL'
      CREATE FUNCTION savings_debt_terms_valid(value jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
      DECLARE field text; rate jsonb; day date; allocated numeric := 0;
      BEGIN
        IF jsonb_typeof(value) IS DISTINCT FROM 'object' OR NOT value ?& ARRAY['label','as_of_on','balance_cents','minimum_payment_cents','apr_bps','due_on','promotional_apr_bps','promotional_expires_on','post_promo_apr_bps','rate_segments','status'] OR (SELECT count(*) FROM jsonb_object_keys(value)) <> 11 THEN RETURN false; END IF;
        IF jsonb_typeof(value->'label') IS DISTINCT FROM 'string' OR length(btrim(value->>'label'))=0 OR length(value->>'label')>120 OR jsonb_typeof(value->'status') IS DISTINCT FROM 'string' OR value->>'status' NOT IN ('active','paid_off','archived') THEN RETURN false; END IF;
        FOREACH field IN ARRAY ARRAY['balance_cents','minimum_payment_cents','apr_bps','promotional_apr_bps','post_promo_apr_bps'] LOOP
          IF value->field <> 'null'::jsonb THEN
            IF jsonb_typeof(value->field) <> 'number' OR (value->>field) !~ '^[0-9]+$' OR (value->>field)::numeric > (CASE WHEN field LIKE '%apr_bps' THEN 100000 ELSE 9223372036854775807 END) THEN RETURN false; END IF;
          END IF;
        END LOOP;
        IF value->>'status'='paid_off' AND value->'balance_cents' IS DISTINCT FROM '0'::jsonb THEN RETURN false; END IF;
        FOREACH field IN ARRAY ARRAY['as_of_on','due_on','promotional_expires_on'] LOOP
          IF value->field <> 'null'::jsonb THEN
            IF jsonb_typeof(value->field) <> 'string' OR value->>field !~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN false; END IF;
            day := (value->>field)::date;
          ELSIF field='as_of_on' THEN RETURN false;
          END IF;
        END LOOP;
        IF jsonb_typeof(value->'rate_segments') IS DISTINCT FROM 'array' OR jsonb_array_length(value->'rate_segments')>8 THEN RETURN false; END IF;
        FOR rate IN SELECT jsonb_array_elements(value->'rate_segments') LOOP
          IF jsonb_typeof(rate) IS DISTINCT FROM 'object' OR NOT rate ?& ARRAY['label','balance_cents','apr_bps','promotional_expires_on','post_promo_apr_bps'] OR (SELECT count(*) FROM jsonb_object_keys(rate))<>5 OR jsonb_typeof(rate->'label') IS DISTINCT FROM 'string' OR length(btrim(rate->>'label'))=0 OR length(rate->>'label')>120 THEN RETURN false; END IF;
          FOREACH field IN ARRAY ARRAY['balance_cents','apr_bps','post_promo_apr_bps'] LOOP
            IF rate->field <> 'null'::jsonb AND (jsonb_typeof(rate->field)<>'number' OR rate->>field !~ '^[0-9]+$' OR (rate->>field)::numeric > (CASE WHEN field LIKE '%apr_bps' THEN 100000 ELSE 9223372036854775807 END)) THEN RETURN false; END IF;
          END LOOP;
          IF rate->'promotional_expires_on' <> 'null'::jsonb THEN
            IF rate->>'promotional_expires_on' !~ '^\d{4}-\d{2}-\d{2}$' OR jsonb_typeof(rate->'promotional_expires_on')<>'string' THEN RETURN false; END IF;
            day := (rate->>'promotional_expires_on')::date;
          END IF;
          allocated := allocated + coalesce((rate->>'balance_cents')::numeric,0);
        END LOOP;
        RETURN value->'balance_cents'='null'::jsonb OR allocated <= (value->>'balance_cents')::numeric;
      EXCEPTION WHEN OTHERS THEN RETURN false;
      END; $$;
      CREATE FUNCTION savings_debt_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE enrollment savings_enrollments; card savings_debt_cards; version savings_debt_versions; prior savings_debt_versions; identity source_account_identity_versions; source_account financial_source_accounts; approval source_revision_approvals;
      BEGIN
        IF TG_OP='DELETE' THEN RAISE EXCEPTION 'participant card identity and history cannot be deleted'; END IF;
        IF TG_TABLE_NAME='savings_debt_cards' THEN
          SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=NEW.savings_enrollment_id;
          PERFORM 1 FROM households WHERE id=enrollment.household_id FOR UPDATE;
          IF NEW.household_id <> enrollment.household_id OR NEW.user_id <> enrollment.user_id THEN RAISE EXCEPTION 'card participant scope invalid'; END IF;
          IF TG_OP='UPDATE' AND ROW(NEW.savings_enrollment_id,NEW.household_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.savings_enrollment_id,OLD.household_id,OLD.user_id) THEN RAISE EXCEPTION 'card identity is frozen'; END IF;
          IF NEW.current_version_id IS NOT NULL THEN
            SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.current_version_id;
            IF version.savings_debt_card_id <> NEW.id OR NEW.source_tracked_account_id IS DISTINCT FROM version.source_tracked_account_id OR (TG_OP='UPDATE' AND NEW.current_version_id IS DISTINCT FROM OLD.current_version_id AND version.previous_version_id IS DISTINCT FROM OLD.current_version_id) THEN RAISE EXCEPTION 'card approved head must advance'; END IF;
          ELSIF NEW.source_tracked_account_id IS NOT NULL OR (TG_OP='UPDATE' AND OLD.current_version_id IS NOT NULL) THEN RAISE EXCEPTION 'approved card head cannot be cleared'; END IF;
          RETURN NEW;
        END IF;
        SELECT * INTO STRICT card FROM savings_debt_cards WHERE id=NEW.savings_debt_card_id;
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=card.savings_enrollment_id;
        PERFORM 1 FROM households WHERE id=enrollment.household_id FOR UPDATE;
        IF NEW.savings_enrollment_id <> enrollment.id THEN RAISE EXCEPTION 'card review enrollment invalid'; END IF;
        IF TG_OP='UPDATE' THEN
          IF TG_TABLE_NAME='savings_debt_versions' THEN RAISE EXCEPTION 'approved card terms are immutable'; END IF;
          IF (to_jsonb(NEW)-ARRAY['status','approved_version_id','lock_version','updated_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','approved_version_id','lock_version','updated_at']) OR OLD.status<>'pending' OR NEW.status<>'approved' THEN RAISE EXCEPTION 'reviewed card draft is frozen'; END IF;
          SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.approved_version_id;
          IF version.id IS DISTINCT FROM card.current_version_id OR version.savings_debt_card_id<>card.id OR version.terms IS DISTINCT FROM NEW.terms OR version.previous_version_id IS DISTINCT FROM NEW.base_version_id OR ROW(version.source_tracked_account_id,version.source_account_identity_version_id,version.source_revision_approval_id,version.source_fingerprint,version.source_snapshot) IS DISTINCT FROM ROW(NEW.source_tracked_account_id,NEW.source_account_identity_version_id,NEW.source_revision_approval_id,NEW.source_fingerprint,NEW.source_snapshot) THEN RAISE EXCEPTION 'card approval does not match reviewed draft'; END IF;
          RETURN NEW;
        END IF;
        IF enrollment.status<>'active' OR NOT EXISTS (SELECT 1 FROM users WHERE id=enrollment.user_id AND role='participant' AND invitation_status<>'revoked') THEN RAISE EXCEPTION 'card review participant unavailable'; END IF;
        IF TG_TABLE_NAME='savings_debt_versions' THEN
          IF NEW.approved_by_user_id<>enrollment.user_id OR NEW.previous_version_id IS DISTINCT FROM card.current_version_id THEN RAISE EXCEPTION 'card approval actor or prior head invalid'; END IF;
          IF NEW.previous_version_id IS NULL THEN
            IF NEW.version_number<>1 THEN RAISE EXCEPTION 'card first version invalid'; END IF;
          ELSE
            SELECT * INTO STRICT prior FROM savings_debt_versions WHERE id=NEW.previous_version_id;
            IF NEW.version_number<>prior.version_number+1 OR btrim(NEW.reason)='' OR (NEW.terms->>'as_of_on')::date < (prior.terms->>'as_of_on')::date THEN RAISE EXCEPTION 'card revision must advance without older statement overwrite'; END IF;
          END IF;
        ELSE
          IF NEW.created_by_user_id<>enrollment.user_id OR NEW.base_version_id IS DISTINCT FROM card.current_version_id OR NEW.base_head_lock_version<>card.lock_version OR NEW.status<>'pending' THEN RAISE EXCEPTION 'card draft actor or head invalid'; END IF;
        END IF;
        IF NEW.source_tracked_account_id IS NOT NULL THEN
          SELECT * INTO STRICT identity FROM source_account_identity_versions WHERE id=NEW.source_account_identity_version_id;
          SELECT a.* INTO STRICT source_account FROM source_account_review_heads h JOIN financial_source_accounts a ON a.id=h.financial_source_account_id WHERE h.id=identity.source_account_review_head_id AND h.approved_version_id=identity.id;
          SELECT * INTO STRICT approval FROM source_revision_approvals WHERE id=NEW.source_revision_approval_id;
          IF identity.household_id<>enrollment.household_id OR identity.source_tracked_account_id<>NEW.source_tracked_account_id OR approval.household_id<>enrollment.household_id OR approval.financial_extraction_revision_id<>source_account.financial_extraction_revision_id OR NOT EXISTS (SELECT 1 FROM source_tracked_accounts WHERE id=NEW.source_tracked_account_id AND household_id=enrollment.household_id AND account_basis='liability') OR NEW.terms->>'as_of_on' IS DISTINCT FROM identity.statement_facts->>'period_end_on' OR NEW.source_snapshot->>'identity_digest' IS DISTINCT FROM identity.digest OR NEW.source_snapshot->>'revision_digest' IS DISTINCT FROM approval.digest OR NEW.source_snapshot->'statement_closing_balance_cents' IS DISTINCT FROM identity.statement_facts->'closing_balance_cents' THEN RAISE EXCEPTION 'card source mapping scope or reviewed facts invalid'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER savings_debt_cards_guard BEFORE INSERT OR UPDATE OR DELETE ON savings_debt_cards FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
      CREATE TRIGGER savings_debt_drafts_guard BEFORE INSERT OR UPDATE OR DELETE ON savings_debt_drafts FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
      CREATE TRIGGER savings_debt_versions_guard BEFORE INSERT OR UPDATE OR DELETE ON savings_debt_versions FOR EACH ROW EXECUTE FUNCTION savings_debt_scope_guard();
    SQL
  end
end
