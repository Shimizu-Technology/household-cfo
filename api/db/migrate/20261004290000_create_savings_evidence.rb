class CreateSavingsEvidence < ActiveRecord::Migration[8.1]
  def up
    create_table :savings_evidence_allocations do |t|
      t.references :household, null: false, foreign_key: true
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :savings_entry_version, null: false, foreign_key: true, index: { unique: true }
      t.bigint :current_version_id
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    create_table :savings_evidence_versions do |t|
      t.references :savings_evidence_allocation, null: false, foreign_key: true
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_version_id
      t.integer :version_number, null: false
      t.integer :approval_sequence, null: false
      t.string :state, null: false
      t.bigint :supported_cents, null: false
      t.jsonb :proof_snapshot, null: false, default: []
      t.boolean :participant_ownership_accepted, null: false
      t.boolean :new_money_reservation_accepted, null: false
      t.string :digest, null: false
      t.string :reason, limit: 500, null: false
      t.datetime :approved_at, null: false
      t.timestamps
    end
    add_index :savings_evidence_versions, [ :id, :savings_evidence_allocation_id ], unique: true, name: "savings_evidence_version_scope"
    add_index :savings_evidence_versions, [ :savings_evidence_allocation_id, :version_number ], unique: true, name: "savings_evidence_version_number"
    add_index :savings_evidence_versions, [ :savings_enrollment_id, :approval_sequence ], unique: true, name: "savings_evidence_sequence"
    add_check_constraint :savings_evidence_versions, "version_number > 0 AND approval_sequence > 0 AND char_length(reason) BETWEEN 1 AND 500 AND digest ~ '^[0-9a-f]{64}$' AND jsonb_typeof(proof_snapshot) = 'array' AND ((state = 'attached' AND supported_cents > 0 AND participant_ownership_accepted AND new_money_reservation_accepted AND jsonb_array_length(proof_snapshot) BETWEEN 1 AND 20) OR (state = 'revoked' AND supported_cents = 0 AND NOT participant_ownership_accepted AND NOT new_money_reservation_accepted AND proof_snapshot = '[]'::jsonb))", name: "savings_evidence_values"
    create_table :savings_evidence_capacities do |t|
      t.references :savings_evidence_version, null: false, foreign_key: true
      t.references :financial_source_event, null: false, foreign_key: true
      t.references :source_review_version, null: false, foreign_key: true
      t.bigint :capacity_cents, null: false
      t.bigint :reserved_cents, null: false
      t.timestamps
    end
    add_index :savings_evidence_capacities, [ :savings_evidence_version_id, :financial_source_event_id ], unique: true, name: "savings_evidence_event_once"
    add_check_constraint :savings_evidence_capacities, "reserved_cents > 0 AND capacity_cents >= reserved_cents", name: "savings_evidence_capacity_values"
    execute "ALTER TABLE savings_evidence_allocations ADD CONSTRAINT savings_evidence_head_scope FOREIGN KEY (current_version_id,id) REFERENCES savings_evidence_versions(id,savings_evidence_allocation_id)"
    execute "ALTER TABLE savings_evidence_versions ADD CONSTRAINT savings_evidence_prior_scope FOREIGN KEY (previous_version_id,savings_evidence_allocation_id) REFERENCES savings_evidence_versions(id,savings_evidence_allocation_id)"
    install_guards
  end

  def down
    execute "LOCK TABLE savings_evidence_allocations, savings_evidence_versions, savings_evidence_capacities IN ACCESS EXCLUSIVE MODE"
    raise ActiveRecord::IrreversibleMigration, "Reviewed evidence history must be preserved" if select_value("SELECT EXISTS (SELECT 1 FROM savings_evidence_allocations)")
    %w[savings_entry_versions savings_plan_versions savings_zero_attestations].each do |table|
      execute "DROP TRIGGER #{table}_evidence_sequence ON #{table}"
    end
    execute "DROP TABLE savings_evidence_capacities, savings_evidence_versions, savings_evidence_allocations CASCADE"
    execute "DROP FUNCTION savings_evidence_head_guard(), savings_evidence_version_guard(), savings_evidence_published_guard(), savings_evidence_sequence_guard(), savings_evidence_capacity_guard()"
  end

  private

  def install_guards
    execute <<~SQL
      CREATE FUNCTION savings_evidence_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE enrollment savings_enrollments; head savings_evidence_allocations; prior savings_evidence_versions;
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'approved savings evidence is immutable'; END IF;
        SELECT * INTO STRICT head FROM savings_evidence_allocations WHERE id=NEW.savings_evidence_allocation_id;
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=head.savings_enrollment_id;
        PERFORM 1 FROM households WHERE id=head.household_id FOR UPDATE;
        IF NEW.savings_enrollment_id <> enrollment.id OR NEW.approved_by_user_id <> enrollment.user_id OR enrollment.status <> 'active'
          OR NEW.previous_version_id IS DISTINCT FROM head.current_version_id OR NEW.approval_sequence <> enrollment.approval_sequence THEN
          RAISE EXCEPTION 'savings evidence approval scope or sequence invalid';
        END IF;
        IF NEW.previous_version_id IS NOT NULL THEN
          SELECT * INTO STRICT prior FROM savings_evidence_versions WHERE id=NEW.previous_version_id;
          IF NEW.version_number <> prior.version_number+1 THEN RAISE EXCEPTION 'evidence revision must advance'; END IF;
        ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'invalid first evidence revision'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_evidence_sequence_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (SELECT 1 FROM savings_evidence_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence)
          OR (TG_TABLE_NAME='savings_evidence_versions' AND EXISTS (
            SELECT 1 FROM savings_entry_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
            UNION ALL SELECT 1 FROM savings_plan_versions WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
            UNION ALL SELECT 1 FROM savings_zero_attestations WHERE savings_enrollment_id=NEW.savings_enrollment_id AND approval_sequence=NEW.approval_sequence
          )) THEN RAISE EXCEPTION 'savings evidence sequence already allocated'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_evidence_head_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE enrollment savings_enrollments; entry savings_entry_versions; version savings_evidence_versions; row RECORD; total numeric; expected_bindings jsonb; actual_bindings jsonb;
      BEGIN
        IF TG_OP='DELETE' THEN RAISE EXCEPTION 'evidence identity cannot be deleted'; END IF;
        IF TG_OP='UPDATE' AND ROW(NEW.household_id,NEW.savings_enrollment_id,NEW.savings_entry_version_id) IS DISTINCT FROM ROW(OLD.household_id,OLD.savings_enrollment_id,OLD.savings_entry_version_id) THEN RAISE EXCEPTION 'evidence identity is frozen'; END IF;
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id=NEW.savings_enrollment_id;
        SELECT * INTO STRICT entry FROM savings_entry_versions WHERE id=NEW.savings_entry_version_id;
        IF enrollment.household_id <> NEW.household_id OR entry.savings_enrollment_id <> enrollment.id THEN RAISE EXCEPTION 'evidence household or entry scope invalid'; END IF;
        PERFORM 1 FROM households WHERE id=NEW.household_id FOR UPDATE;
        IF NEW.current_version_id IS NOT NULL THEN
          SELECT * INTO STRICT version FROM savings_evidence_versions WHERE id=NEW.current_version_id;
          IF version.savings_evidence_allocation_id <> NEW.id OR (TG_OP='UPDATE' AND NEW.current_version_id IS DISTINCT FROM OLD.current_version_id AND version.previous_version_id IS DISTINCT FROM OLD.current_version_id) THEN RAISE EXCEPTION 'evidence head must advance'; END IF;
          IF version.state='attached' THEN
            IF entry.signed_cents <= 0 OR entry.funding_source NOT IN ('earned_income','gift','bonus','new_money_reserved') OR version.supported_cents > entry.signed_cents OR entry.id IS DISTINCT FROM (SELECT current_approved_version_id FROM savings_entries WHERE id=entry.savings_entry_id) THEN RAISE EXCEPTION 'evidence must support current eligible contribution'; END IF;
            IF (SELECT SUM((proof->>'amount_cents')::bigint) FROM jsonb_array_elements(version.proof_snapshot) proof) <> version.supported_cents THEN RAISE EXCEPTION 'evidence proof total invalid'; END IF;
            SELECT jsonb_agg(binding ORDER BY (binding->>'event_id')::bigint) INTO expected_bindings FROM jsonb_array_elements(version.proof_snapshot) proof, jsonb_array_elements(proof->'bindings') binding;
            SELECT jsonb_agg(jsonb_build_object('event_id',financial_source_event_id,'source_review_version_id',source_review_version_id,'capacity_cents',capacity_cents,'reserved_cents',reserved_cents) ORDER BY financial_source_event_id)
              INTO actual_bindings FROM savings_evidence_capacities WHERE savings_evidence_version_id=version.id;
            IF actual_bindings IS DISTINCT FROM expected_bindings THEN RAISE EXCEPTION 'evidence capacity bindings do not match reviewed proof'; END IF;
            FOR row IN SELECT c.*, e.household_id AS event_household, h.financial_source_event_id AS reviewed_event, abs(v.signed_amount_cents) AS reviewed_capacity
              FROM savings_evidence_capacities c JOIN financial_source_events e ON e.id=c.financial_source_event_id
              JOIN source_review_versions v ON v.id=c.source_review_version_id JOIN source_review_heads h ON h.id=v.source_review_head_id WHERE c.savings_evidence_version_id=version.id LOOP
              IF row.event_household <> NEW.household_id OR row.reviewed_event <> row.financial_source_event_id OR row.capacity_cents > row.reviewed_capacity THEN RAISE EXCEPTION 'canonical evidence capacity scope invalid'; END IF;
              SELECT COALESCE(SUM(c.reserved_cents),0) INTO total FROM savings_evidence_capacities c JOIN savings_evidence_allocations a ON a.current_version_id=c.savings_evidence_version_id
                WHERE a.id <> NEW.id AND c.financial_source_event_id=row.financial_source_event_id;
              IF total + row.reserved_cents > row.capacity_cents THEN RAISE EXCEPTION 'canonical movement evidence capacity exceeded'; END IF;
            END LOOP;
            IF NOT EXISTS (SELECT 1 FROM savings_evidence_capacities WHERE savings_evidence_version_id=version.id) THEN RAISE EXCEPTION 'evidence requires canonical capacity bindings'; END IF;
          END IF;
        ELSIF TG_OP='UPDATE' AND OLD.current_version_id IS NOT NULL THEN RAISE EXCEPTION 'evidence cannot hide its history'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_evidence_published_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT current_version_id FROM savings_evidence_allocations WHERE id=NEW.savings_evidence_allocation_id) IS DISTINCT FROM
          (SELECT id FROM savings_evidence_versions WHERE savings_evidence_allocation_id=NEW.savings_evidence_allocation_id ORDER BY version_number DESC LIMIT 1)
          THEN RAISE EXCEPTION 'evidence revision must publish atomically'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_evidence_capacity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'evidence capacities are immutable'; END IF;
        IF EXISTS (SELECT 1 FROM savings_evidence_versions v JOIN savings_evidence_allocations a ON a.id=v.savings_evidence_allocation_id
          WHERE v.id=NEW.savings_evidence_version_id AND (a.current_version_id=v.id OR v.previous_version_id IS DISTINCT FROM a.current_version_id)) THEN RAISE EXCEPTION 'published capacity bindings are terminal'; END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER savings_evidence_identity BEFORE INSERT OR UPDATE OR DELETE ON savings_evidence_allocations FOR EACH ROW EXECUTE FUNCTION savings_evidence_head_guard();
      CREATE TRIGGER savings_evidence_version_immutable BEFORE INSERT OR UPDATE OR DELETE ON savings_evidence_versions FOR EACH ROW EXECUTE FUNCTION savings_evidence_version_guard();
      CREATE TRIGGER savings_evidence_capacity_immutable BEFORE INSERT OR UPDATE OR DELETE ON savings_evidence_capacities FOR EACH ROW EXECUTE FUNCTION savings_evidence_capacity_guard();
      CREATE CONSTRAINT TRIGGER savings_evidence_published AFTER INSERT ON savings_evidence_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION savings_evidence_published_guard();
    SQL
    %w[savings_entry_versions savings_plan_versions savings_zero_attestations savings_evidence_versions].each do |table|
      execute "CREATE TRIGGER #{table}_evidence_sequence BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_evidence_sequence_guard()"
    end
  end
end
