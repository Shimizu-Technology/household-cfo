class CreateSavingsChallengeFoundation < ActiveRecord::Migration[8.1]
  def up
    add_column :cohorts, :savings_challenge_enabled, :boolean, null: false, default: false
    add_column :cohorts, :savings_challenge_release_hold, :boolean, null: false, default: true
    add_column :cohorts, :savings_challenge_capacity, :integer, null: false, default: 30
    add_column :cohorts, :savings_challenge_policy_version, :string, null: false, default: "1"
    add_check_constraint :cohorts, "savings_challenge_capacity BETWEEN 1 AND 30", name: "savings_challenge_capacity_valid"

    create_table :savings_enrollments do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :cohort, null: false, foreign_key: true
      t.bigint :accepted_cohort_membership_id, null: false
      t.datetime :membership_started_at, null: false
      t.datetime :accepted_at, null: false
      t.date :accepted_local_on, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :time_zone, null: false, default: "Pacific/Guam"
      t.string :policy_version, null: false
      t.boolean :late_start_accepted, null: false, default: false
      t.string :status, null: false, default: "active"
      t.bigint :current_accepted_plan_version_id
      t.integer :approval_sequence, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :savings_enrollments, [ :cohort_id, :user_id ], unique: true
    add_check_constraint :savings_enrollments, "ends_on = starts_on + 89 AND time_zone = 'Pacific/Guam' AND starts_on >= accepted_local_on", name: "savings_enrollment_calendar_valid"
    add_check_constraint :savings_enrollments, "status IN ('active','withdrawn','completed') AND approval_sequence >= 0", name: "savings_enrollment_state_valid"

    create_table :savings_plan_versions do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_version_id
      t.integer :version_number, null: false
      t.integer :approval_sequence, null: false
      t.bigint :target_cents
      t.string :reason, limit: 500, null: false, default: ""
      t.datetime :approved_at, null: false
      t.timestamps
    end
    add_index :savings_plan_versions, [ :savings_enrollment_id, :version_number ], unique: true, name: "idx_savings_plan_number"
    add_index :savings_plan_versions, [ :id, :savings_enrollment_id ], unique: true, name: "idx_savings_plan_scope"
    add_check_constraint :savings_plan_versions, "(target_cents IS NULL OR target_cents > 0) AND version_number > 0 AND approval_sequence > 0", name: "savings_plan_values_valid"

    create_table :savings_plan_drafts do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :base_plan_version_id
      t.bigint :approved_plan_version_id
      t.bigint :target_cents
      t.string :reason, limit: 500, null: false, default: ""
      t.string :status, null: false, default: "pending"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :savings_plan_drafts, "(target_cents IS NULL OR target_cents > 0) AND status IN ('pending','approved')", name: "savings_plan_draft_values_valid"

    create_table :savings_entries do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.bigint :current_approved_version_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :savings_entries, [ :id, :savings_enrollment_id ], unique: true, name: "idx_savings_entry_scope"

    create_table :savings_entry_versions do |t|
      t.references :savings_entry, null: false, foreign_key: true
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_version_id
      t.integer :version_number, null: false
      t.integer :approval_sequence, null: false
      t.bigint :signed_cents, null: false
      t.date :effective_on, null: false
      t.string :currency, null: false, default: "USD"
      t.string :funding_source, null: false
      t.bigint :evidence_supported_cents, null: false, default: 0
      t.string :reason, limit: 500, null: false, default: ""
      t.datetime :approved_at, null: false
      t.timestamps
    end
    add_index :savings_entry_versions, [ :savings_entry_id, :version_number ], unique: true, name: "idx_savings_entry_version_number"
    add_index :savings_entry_versions, [ :id, :savings_entry_id ], unique: true, name: "idx_savings_version_scope"
    add_index :savings_entry_versions, [ :savings_enrollment_id, :approval_sequence ], unique: true, name: "idx_savings_entry_approval_sequence"
    add_check_constraint :savings_entry_versions, "currency = 'USD' AND evidence_supported_cents = 0 AND version_number > 0 AND approval_sequence > 0 AND ((funding_source = 'withdrawal' AND signed_cents <= 0) OR (funding_source IN ('earned_income','gift','bonus','new_money_reserved','preexisting','borrowed','cash_advance','existing_internal_money') AND signed_cents >= 0))", name: "savings_entry_version_values_valid"

    create_table :savings_entry_drafts do |t|
      t.references :savings_entry, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :base_version_id
      t.integer :base_entry_lock_version, null: false
      t.bigint :approved_version_id
      t.bigint :signed_cents, null: false
      t.date :effective_on, null: false
      t.string :funding_source, null: false
      t.string :reason, limit: 500, null: false, default: ""
      t.string :status, null: false, default: "pending"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :savings_entry_drafts, "status IN ('pending','approved') AND base_entry_lock_version >= 0", name: "savings_entry_draft_state_valid"

    create_table :savings_zero_attestations do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_attestation_id
      t.date :cutoff_on, null: false
      t.integer :approval_sequence, null: false
      t.datetime :approved_at, null: false
      t.timestamps
    end
    add_foreign_key :savings_zero_attestations, :savings_zero_attestations, column: :previous_attestation_id
    add_index :savings_zero_attestations, [ :savings_enrollment_id, :approval_sequence ], unique: true, name: "idx_savings_zero_approval_sequence"

    scoped_fk("savings_enrollments", "current_accepted_plan_version_id, id", "savings_plan_versions", "id, savings_enrollment_id", "savings_enrollment_plan_scope")
    scoped_fk("savings_entries", "current_approved_version_id, id", "savings_entry_versions", "id, savings_entry_id", "savings_entry_head_scope")
    scoped_fk("savings_entry_versions", "savings_entry_id, savings_enrollment_id", "savings_entries", "id, savings_enrollment_id", "savings_version_enrollment_scope")
    scoped_fk("savings_entry_versions", "previous_version_id, savings_entry_id", "savings_entry_versions", "id, savings_entry_id", "savings_version_previous_scope")
    scoped_fk("savings_plan_versions", "previous_version_id, savings_enrollment_id", "savings_plan_versions", "id, savings_enrollment_id", "savings_plan_previous_scope")
    %w[base_plan_version_id approved_plan_version_id].each do |column|
      scoped_fk("savings_plan_drafts", "#{column}, savings_enrollment_id", "savings_plan_versions", "id, savings_enrollment_id", "savings_draft_#{column}_scope")
    end
    %w[base_version_id approved_version_id].each do |column|
      scoped_fk("savings_entry_drafts", "#{column}, savings_entry_id", "savings_entry_versions", "id, savings_entry_id", "savings_draft_#{column}_scope")
    end
    install_guards
  end

  def down
    tables = %w[savings_entry_drafts savings_plan_drafts savings_zero_attestations savings_entries savings_entry_versions savings_enrollments savings_plan_versions]
    execute "LOCK TABLE cohorts, #{tables.join(', ')} IN ACCESS EXCLUSIVE MODE"
    populated = tables.any? { |table| select_value("SELECT EXISTS (SELECT 1 FROM #{table})") }
    configured = select_value("SELECT EXISTS (SELECT 1 FROM cohorts WHERE savings_challenge_enabled IS DISTINCT FROM false OR savings_challenge_release_hold IS DISTINCT FROM true OR savings_challenge_capacity <> 30 OR savings_challenge_policy_version <> '1')")
    raise ActiveRecord::IrreversibleMigration, "Savings challenge data or configuration must be preserved" if populated || configured
    %w[savings_entry_drafts savings_plan_drafts savings_zero_attestations savings_entries savings_entry_versions savings_enrollments savings_plan_versions].each { |table| execute "DROP TABLE #{table} CASCADE" }
    execute "DROP FUNCTION IF EXISTS savings_prevent_mutation(), savings_scope_guard(), savings_identity_guard(), savings_draft_guard(), savings_approval_head_guard()"
    remove_check_constraint :cohorts, name: "savings_challenge_capacity_valid"
    %i[savings_challenge_enabled savings_challenge_release_hold savings_challenge_capacity savings_challenge_policy_version].each { |column| remove_column :cohorts, column }
  end

  private

  def scoped_fk(table, columns, target, target_columns, name)
    execute "ALTER TABLE #{table} ADD CONSTRAINT #{name} FOREIGN KEY (#{columns}) REFERENCES #{target} (#{target_columns}) ON DELETE RESTRICT"
  end

  def install_guards
    execute <<~SQL
      CREATE FUNCTION savings_prevent_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'approved savings history is immutable' USING ERRCODE = 'integrity_constraint_violation'; END; $$;
      CREATE FUNCTION savings_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE enrollment savings_enrollments; prior RECORD;
      BEGIN
        SELECT * INTO STRICT enrollment FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
        IF NEW.approved_by_user_id <> enrollment.user_id OR enrollment.status <> 'active' THEN
          RAISE EXCEPTION 'savings approval participant boundary' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.approval_sequence <> enrollment.approval_sequence OR EXISTS (
          SELECT 1 FROM savings_entry_versions WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
          UNION ALL SELECT 1 FROM savings_plan_versions WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
          UNION ALL SELECT 1 FROM savings_zero_attestations WHERE savings_enrollment_id = enrollment.id AND approval_sequence = NEW.approval_sequence
        ) THEN RAISE EXCEPTION 'savings approval sequence must advance exclusively'; END IF;
        IF TG_TABLE_NAME = 'savings_entry_versions' THEN
          IF NEW.previous_version_id IS DISTINCT FROM (SELECT current_approved_version_id FROM savings_entries WHERE id = NEW.savings_entry_id) THEN
            RAISE EXCEPTION 'savings approval must replace the current approved head';
          END IF;
          IF NEW.effective_on NOT BETWEEN enrollment.starts_on AND enrollment.ends_on THEN
            RAISE EXCEPTION 'savings effective date outside challenge' USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF NEW.previous_version_id IS NOT NULL THEN
            SELECT * INTO STRICT prior FROM savings_entry_versions WHERE id = NEW.previous_version_id;
            IF NEW.version_number <> prior.version_number + 1 THEN RAISE EXCEPTION 'savings version sequence invalid'; END IF;
          ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'savings initial version invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'savings_plan_versions' THEN
          IF NEW.previous_version_id IS DISTINCT FROM enrollment.current_accepted_plan_version_id THEN RAISE EXCEPTION 'savings plan must replace current head'; END IF;
          IF NEW.previous_version_id IS NOT NULL THEN
            SELECT * INTO STRICT prior FROM savings_plan_versions WHERE id = NEW.previous_version_id;
            IF NEW.version_number <> prior.version_number + 1 THEN RAISE EXCEPTION 'savings plan sequence invalid'; END IF;
          ELSIF NEW.version_number <> 1 THEN RAISE EXCEPTION 'savings initial plan invalid'; END IF;
        ELSE
          IF NEW.cutoff_on NOT BETWEEN enrollment.starts_on AND enrollment.ends_on OR EXISTS (
            SELECT 1 FROM savings_entries e JOIN savings_entry_versions v ON v.id = e.current_approved_version_id
            WHERE e.savings_enrollment_id = enrollment.id AND v.effective_on <= NEW.cutoff_on
              AND v.funding_source IN ('earned_income','gift','bonus','new_money_reserved','withdrawal')
          ) THEN RAISE EXCEPTION 'savings zero attestation conflicts with ledger' USING ERRCODE = 'integrity_constraint_violation'; END IF;
          IF NEW.previous_attestation_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM savings_zero_attestations z WHERE z.id = NEW.previous_attestation_id AND z.savings_enrollment_id = enrollment.id AND z.cutoff_on = NEW.cutoff_on
          ) THEN RAISE EXCEPTION 'savings zero attestation scope invalid'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'savings identity cannot be deleted'; END IF;
        IF TG_TABLE_NAME = 'savings_enrollments' THEN
          IF ROW(NEW.user_id,NEW.household_id,NEW.cohort_id,NEW.accepted_cohort_membership_id,NEW.membership_started_at,NEW.accepted_at,NEW.accepted_local_on,NEW.starts_on,NEW.ends_on,NEW.time_zone,NEW.policy_version,NEW.late_start_accepted)
            IS DISTINCT FROM ROW(OLD.user_id,OLD.household_id,OLD.cohort_id,OLD.accepted_cohort_membership_id,OLD.membership_started_at,OLD.accepted_at,OLD.accepted_local_on,OLD.starts_on,OLD.ends_on,OLD.time_zone,OLD.policy_version,OLD.late_start_accepted) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'; END IF;
          IF NEW.current_accepted_plan_version_id IS DISTINCT FROM OLD.current_accepted_plan_version_id AND NOT EXISTS (
            SELECT 1 FROM savings_plan_versions v WHERE v.id = NEW.current_accepted_plan_version_id AND v.previous_version_id IS NOT DISTINCT FROM OLD.current_accepted_plan_version_id
          ) THEN RAISE EXCEPTION 'savings plan head must advance'; END IF;
        ELSE
          IF NEW.savings_enrollment_id <> OLD.savings_enrollment_id THEN RAISE EXCEPTION 'savings entry identity is frozen'; END IF;
          IF NEW.current_approved_version_id IS DISTINCT FROM OLD.current_approved_version_id AND NOT EXISTS (
            SELECT 1 FROM savings_entry_versions v WHERE v.id = NEW.current_approved_version_id AND v.previous_version_id IS NOT DISTINCT FROM OLD.current_approved_version_id
          ) THEN RAISE EXCEPTION 'savings entry head must advance'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_draft_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN IF OLD.status = 'approved' THEN RAISE EXCEPTION 'approved savings draft is terminal'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END; $$;
      CREATE FUNCTION savings_approval_head_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE head_number integer; latest_number integer;
      BEGIN
        IF TG_TABLE_NAME = 'savings_entry_versions' THEN
          SELECT v.version_number INTO head_number FROM savings_entries e JOIN savings_entry_versions v ON v.id = e.current_approved_version_id WHERE e.id = NEW.savings_entry_id;
          SELECT MAX(version_number) INTO latest_number FROM savings_entry_versions WHERE savings_entry_id = NEW.savings_entry_id;
        ELSE
          SELECT v.version_number INTO head_number FROM savings_enrollments e JOIN savings_plan_versions v ON v.id = e.current_accepted_plan_version_id WHERE e.id = NEW.savings_enrollment_id;
          SELECT MAX(version_number) INTO latest_number FROM savings_plan_versions WHERE savings_enrollment_id = NEW.savings_enrollment_id;
        END IF;
        IF head_number IS DISTINCT FROM latest_number THEN RAISE EXCEPTION 'approved savings version must publish its current head atomically'; END IF;
        RETURN NEW;
      END; $$;
    SQL
    %w[savings_plan_versions savings_entry_versions savings_zero_attestations].each do |table|
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_prevent_mutation()"
      execute "CREATE TRIGGER #{table}_scope BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_scope_guard()"
    end
    %w[savings_enrollments savings_entries].each do |table|
      execute "CREATE TRIGGER #{table}_identity BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_identity_guard()"
    end
    %w[savings_plan_drafts savings_entry_drafts].each do |table|
      execute "CREATE TRIGGER #{table}_terminal BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_draft_guard()"
    end
    %w[savings_plan_versions savings_entry_versions].each do |table|
      execute "CREATE CONSTRAINT TRIGGER #{table}_published AFTER INSERT ON #{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION savings_approval_head_guard()"
    end
  end
end
