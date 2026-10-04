class CreateSavingsDailyCheckpoints < ActiveRecord::Migration[8.1]
  TABLES = %w[savings_daily_ledgers savings_daily_purchases savings_daily_purchase_drafts savings_daily_purchase_versions savings_daily_reflections savings_daily_reflection_versions savings_daily_check_ins savings_daily_check_in_versions savings_checkpoints savings_checkpoint_drafts savings_checkpoint_versions].freeze

  def up
    create_table :savings_daily_ledgers do |t|
      t.references :savings_enrollment, null: false, foreign_key: true, index: { unique: true }
      t.integer :sequence, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :savings_daily_ledgers, "sequence >= 0", name: "savings_daily_sequence_valid"
    head(:savings_daily_purchases)
    head(:savings_daily_reflections) { |t| t.references :savings_daily_purchase, null: false, foreign_key: true, index: { unique: true } }
    head(:savings_daily_check_ins) { |t| t.date :local_on, null: false }
    head(:savings_checkpoints) { |t| t.integer :milestone_day, null: false }
    add_index :savings_daily_check_ins, [ :savings_enrollment_id, :local_on ], unique: true, name: "idx_daily_check_in_day"
    add_index :savings_checkpoints, [ :savings_enrollment_id, :milestone_day ], unique: true, name: "idx_savings_checkpoint_day"
    add_check_constraint :savings_checkpoints, "milestone_day IN (30,60,90)", name: "savings_checkpoint_day_valid"

    draft(:savings_daily_purchase_drafts, :savings_daily_purchase) do |t|
      purchase_values(t)
      t.string :link_kind, null: false
      t.references :linked_transaction, foreign_key: { to_table: :household_transactions }
      t.string :canonical_digest
      t.string :previous_canonical_digest
    end
    version_table(:savings_daily_purchase_versions, :savings_daily_purchase) do |t|
      purchase_values(t)
      t.integer :daily_sequence, null: false
      t.references :household_transaction, null: false, foreign_key: true
      t.string :link_kind, null: false
      t.date :posted_on
    end
    %w[savings_daily_purchase_drafts savings_daily_purchase_versions].each do |table|
      add_check_constraint table, "((disposition = 'purchase' AND amount_cents BETWEEN 1 AND 2147483647) OR (disposition = 'void' AND amount_cents = 0 AND splits = '[]'::jsonb AND link_kind = 'manual_new')) AND char_length(merchant) BETWEEN 1 AND 120 AND link_kind IN ('manual_new','existing_transaction') AND jsonb_typeof(splits) = 'array'", name: "#{table}_values"
    end
    version_table(:savings_daily_reflection_versions, :savings_daily_reflection) do |t|
      t.string :feeling_then, limit: 500
      t.string :feeling_now, limit: 500
      t.datetime :erased_at
      t.references :erased_by_user, foreign_key: { to_table: :users }
    end
    version_table(:savings_daily_check_in_versions, :savings_daily_check_in) do |t|
      t.string :spending_state, null: false
      t.integer :daily_sequence, null: false
    end
    add_check_constraint :savings_daily_check_in_versions, "spending_state IN ('spending','no_spend','unknown')", name: "savings_daily_check_in_state"
    draft(:savings_checkpoint_drafts, :savings_checkpoint) { |t| t.jsonb :snapshot, null: false, default: {} }
    version_table(:savings_checkpoint_versions, :savings_checkpoint) { |t| t.jsonb :snapshot, null: false, default: {} }
    %w[savings_checkpoint_drafts savings_checkpoint_versions].each do |table|
      add_check_constraint table, "jsonb_typeof(snapshot) = 'object'", name: "#{table}_snapshot"
    end
    %w[savings_daily_purchase_versions savings_daily_check_in_versions].each do |table|
      add_index table, [ :savings_enrollment_id, :daily_sequence ], unique: true, name: "#{table}_sequence"
      add_check_constraint table, "daily_sequence > 0", name: "#{table}_sequence_valid"
    end
    %i[savings_daily_purchase savings_daily_reflection savings_daily_check_in savings_checkpoint].each do |singular|
      table = singular.to_s.pluralize
      versions = "#{singular}_versions"
      scoped_fk(table, "current_version_id, id", versions, "id, #{singular}_id", "#{table}_current_scope")
    end
    scoped_fk("savings_daily_reflections", "savings_daily_purchase_id, savings_enrollment_id", "savings_daily_purchases", "id, savings_enrollment_id", "daily_reflection_purchase_scope")
    @deferred_draft_fks.each { |arguments| scoped_fk(*arguments) }
    install_guards
  end

  def down
    execute "LOCK TABLE #{TABLES.join(', ')} IN ACCESS EXCLUSIVE MODE"
    if TABLES.any? { |table| select_value("SELECT EXISTS (SELECT 1 FROM #{table})") }
      raise ActiveRecord::IrreversibleMigration, "Daily and checkpoint history must be preserved"
    end
    TABLES.reverse_each { |table| execute "DROP TABLE #{table} CASCADE" }
    execute "DROP FUNCTION IF EXISTS savings_daily_version_guard(), savings_daily_head_guard(), savings_daily_reflection_guard(), savings_daily_draft_guard()"
  end

  private

  def head(table)
    create_table table do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.bigint :current_version_id
      t.integer :lock_version, null: false, default: 0
      yield(t) if block_given?
      t.timestamps
    end
    add_index table, [ :id, :savings_enrollment_id ], unique: true, name: "#{table}_scope"
  end

  def draft(table, parent)
    create_table table do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references parent, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :base_version_id
      t.integer :base_head_lock_version, null: false
      t.bigint :approved_version_id
      t.string :status, null: false, default: "pending"
      t.string :reason, limit: 500, null: false, default: ""
      t.integer :lock_version, null: false, default: 0
      yield(t)
      t.timestamps
    end
    add_check_constraint table, "status IN ('pending','approved') AND base_head_lock_version >= 0", name: "#{table}_state"
    scoped_fk(table, "#{parent}_id, savings_enrollment_id", parent.to_s.pluralize, "id, savings_enrollment_id", "#{table}_scope")
    %w[base_version_id approved_version_id].each do |column|
      (@deferred_draft_fks ||= []) << [ table, "#{column}, #{parent}_id", "#{parent}_versions", "id, #{parent}_id", "#{table}_#{column}" ]
    end
  end

  def version_table(table, parent)
    create_table table do |t|
      t.references :savings_enrollment, null: false, foreign_key: true
      t.references parent, null: false, foreign_key: true
      t.references :approved_by_user, null: false, foreign_key: { to_table: :users }
      t.bigint :previous_version_id
      t.integer :version_number, null: false
      t.string :reason, limit: 500, null: false, default: ""
      t.datetime :approved_at, null: false
      yield(t)
      t.timestamps
    end
    add_index table, [ parent.to_s + "_id", :version_number ], unique: true, name: "#{table}_number"
    add_index table, [ :id, parent.to_s + "_id" ], unique: true, name: "#{table}_scope"
    add_check_constraint table, "version_number > 0", name: "#{table}_number_valid"
    scoped_fk(table, "#{parent}_id, savings_enrollment_id", parent.to_s.pluralize, "id, savings_enrollment_id", "#{table}_parent_scope")
    scoped_fk(table, "previous_version_id, #{parent}_id", table, "id, #{parent}_id", "#{table}_previous_scope")
  end

  def purchase_values(t)
    t.string :disposition, null: false, default: "purchase"
    t.bigint :amount_cents, null: false
    t.string :merchant, limit: 120, null: false
    t.date :purchased_on, null: false
    t.jsonb :splits, null: false, default: []
  end

  def scoped_fk(table, columns, target, target_columns, name)
    execute "ALTER TABLE #{table} ADD CONSTRAINT #{name} FOREIGN KEY (#{columns}) REFERENCES #{target} (#{target_columns}) ON DELETE RESTRICT"
  end

  def install_guards
    execute <<~SQL
      CREATE FUNCTION savings_daily_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE e savings_enrollments; h RECORD; prior RECORD; data jsonb;
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'daily approved history is immutable'; END IF;
        SELECT * INTO STRICT e FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
        IF NEW.approved_by_user_id <> e.user_id OR e.status NOT IN ('active','completed') THEN RAISE EXCEPTION 'daily participant boundary'; END IF;
        data := to_jsonb(NEW);
        EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_ARGV[0]) INTO STRICT h USING (data->>TG_ARGV[1])::bigint;
        IF NEW.previous_version_id IS DISTINCT FROM h.current_version_id THEN RAISE EXCEPTION 'daily stale predecessor'; END IF;
        IF NEW.previous_version_id IS NULL THEN
          IF NEW.version_number <> 1 THEN RAISE EXCEPTION 'daily first version'; END IF;
        ELSE
          EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_TABLE_NAME) INTO STRICT prior USING NEW.previous_version_id;
          IF NEW.version_number <> prior.version_number + 1 OR char_length(trim(NEW.reason)) = 0 THEN RAISE EXCEPTION 'daily correction needs reason'; END IF;
        END IF;
        IF data ? 'daily_sequence' AND NOT EXISTS (SELECT 1 FROM savings_daily_ledgers l WHERE l.savings_enrollment_id = e.id AND l.sequence = (data->>'daily_sequence')::integer) THEN RAISE EXCEPTION 'daily sequence boundary'; END IF;
        IF TG_TABLE_NAME = 'savings_daily_purchase_versions' THEN
          IF (data->>'purchased_on')::date NOT BETWEEN e.starts_on AND LEAST(e.ends_on,(NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date) OR NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.household_id = e.household_id) THEN RAISE EXCEPTION 'daily purchase scope'; END IF;
          IF data->>'disposition' = 'void' THEN
            IF NEW.previous_version_id IS NULL OR to_jsonb(prior)->>'disposition' <> 'purchase' OR to_jsonb(prior)->>'link_kind' <> 'manual_new' OR
              data->>'household_transaction_id' IS DISTINCT FROM to_jsonb(prior)->>'household_transaction_id' OR
              NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.financial_source_event_id IS NULL AND tx.status = 'ignored' AND (tx.metadata->>'savings_daily_purchase_id')::bigint = h.id) THEN RAISE EXCEPTION 'daily void ownership'; END IF;
          ELSE
            IF NOT EXISTS (SELECT 1 FROM household_transactions tx WHERE tx.id = (data->>'household_transaction_id')::bigint AND tx.total_amount_cents = (data->>'amount_cents')::bigint AND tx.merchant = data->>'merchant' AND tx.status IN ('confirmed','reconciled')) THEN RAISE EXCEPTION 'daily canonical facts'; END IF;
          END IF;
        ELSIF TG_TABLE_NAME = 'savings_daily_check_in_versions' THEN
          IF (to_jsonb(h)->>'local_on')::date NOT BETWEEN e.starts_on AND LEAST(e.ends_on,(NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date) THEN RAISE EXCEPTION 'daily check-in calendar'; END IF;
          IF data->>'spending_state' = 'no_spend' AND EXISTS (SELECT 1 FROM savings_daily_purchase_versions v JOIN savings_daily_purchases p ON p.current_version_id = v.id WHERE v.savings_enrollment_id = e.id AND v.purchased_on = (to_jsonb(h)->>'local_on')::date AND v.disposition = 'purchase') THEN RAISE EXCEPTION 'daily no-spend conflicts with approved purchase'; END IF;
        ELSIF TG_TABLE_NAME = 'savings_checkpoint_versions' THEN
          IF data->'snapshot'->>'calculation_version' <> 'savings_checkpoint_v1' OR
            (data->'snapshot'->>'milestone_day')::integer IS DISTINCT FROM (to_jsonb(h)->>'milestone_day')::integer OR
            (data->'snapshot'->>'cutoff_on')::date IS DISTINCT FROM e.starts_on + (to_jsonb(h)->>'milestone_day')::integer - 1 OR
            (data->'snapshot'->>'cutoff_on')::date > (NEW.approved_at AT TIME ZONE 'UTC' AT TIME ZONE e.time_zone)::date OR
            data->'snapshot'->>'time_zone' IS DISTINCT FROM e.time_zone OR
            (data->'snapshot'->>'accepted_cohort_release_id')::bigint IS DISTINCT FROM e.accepted_cohort_release_id OR
            (data->'snapshot'->>'financial_approval_sequence')::integer IS DISTINCT FROM e.approval_sequence OR
            (data->'snapshot'->>'daily_approval_sequence')::integer IS DISTINCT FROM COALESCE((SELECT sequence FROM savings_daily_ledgers WHERE savings_enrollment_id=e.id),0) THEN RAISE EXCEPTION 'checkpoint frozen boundary'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_daily_head_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE version RECORD; data jsonb;
      BEGIN
        IF NEW.savings_enrollment_id IS DISTINCT FROM OLD.savings_enrollment_id THEN RAISE EXCEPTION 'daily identity is frozen'; END IF;
        IF NEW.current_version_id IS DISTINCT FROM OLD.current_version_id THEN
          EXECUTE format('SELECT * FROM %I WHERE id = $1', TG_ARGV[0]) INTO STRICT version USING NEW.current_version_id;
          data := to_jsonb(version);
          IF (data->>TG_ARGV[1])::bigint <> NEW.id OR version.previous_version_id IS DISTINCT FROM OLD.current_version_id THEN RAISE EXCEPTION 'daily head must advance'; END IF;
        END IF;
        IF TG_TABLE_NAME = 'savings_daily_check_ins' AND (to_jsonb(NEW)->'local_on') IS DISTINCT FROM (to_jsonb(OLD)->'local_on') THEN RAISE EXCEPTION 'daily date is frozen'; END IF;
        IF TG_TABLE_NAME = 'savings_checkpoints' AND (to_jsonb(NEW)->'milestone_day') IS DISTINCT FROM (to_jsonb(OLD)->'milestone_day') THEN RAISE EXCEPTION 'checkpoint milestone is frozen'; END IF;
        IF TG_TABLE_NAME = 'savings_daily_reflections' AND (to_jsonb(NEW)->'savings_daily_purchase_id') IS DISTINCT FROM (to_jsonb(OLD)->'savings_daily_purchase_id') THEN RAISE EXCEPTION 'reflection purchase is frozen'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_daily_draft_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.status <> 'pending' THEN RAISE EXCEPTION 'approved daily draft is immutable'; END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        IF NEW.savings_enrollment_id IS DISTINCT FROM OLD.savings_enrollment_id OR NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id THEN RAISE EXCEPTION 'daily draft identity is frozen'; END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION savings_daily_reflection_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE e savings_enrollments;
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'reflection audit identity is retained'; END IF;
        SELECT * INTO STRICT e FROM savings_enrollments WHERE id = NEW.savings_enrollment_id;
        IF OLD.erased_at IS NOT NULL AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN RAISE EXCEPTION 'reflection tombstone is immutable'; END IF;
        IF (to_jsonb(NEW) - ARRAY['feeling_then','feeling_now','reason','erased_at','erased_by_user_id','updated_at']) IS DISTINCT FROM
           (to_jsonb(OLD) - ARRAY['feeling_then','feeling_now','reason','erased_at','erased_by_user_id','updated_at']) OR NEW.feeling_then IS NOT NULL OR NEW.feeling_now IS NOT NULL OR NEW.reason <> '' OR NEW.erased_at IS NULL OR NEW.erased_by_user_id <> e.user_id THEN RAISE EXCEPTION 'reflection permits only private-text erasure'; END IF;
        RETURN NEW;
      END; $$;
    SQL
    %i[savings_daily_purchase savings_daily_reflection savings_daily_check_in savings_checkpoint].each do |parent|
      table = parent.to_s.pluralize
      versions = "#{parent}_versions"
      execute "CREATE TRIGGER #{table}_head BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_daily_head_guard('#{versions}','#{parent}_id')"
      execute "CREATE TRIGGER #{versions}_insert BEFORE INSERT ON #{versions} FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('#{table}','#{parent}_id')"
      if parent == :savings_daily_reflection
        execute "CREATE TRIGGER #{versions}_immutable BEFORE UPDATE OR DELETE ON #{versions} FOR EACH ROW EXECUTE FUNCTION savings_daily_reflection_guard()"
      else
        execute "CREATE TRIGGER #{versions}_immutable BEFORE UPDATE OR DELETE ON #{versions} FOR EACH ROW EXECUTE FUNCTION savings_daily_version_guard('#{table}','#{parent}_id')"
      end
    end
    %w[savings_daily_purchase_drafts savings_checkpoint_drafts].each do |table|
      execute "CREATE TRIGGER #{table}_terminal BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION savings_daily_draft_guard()"
    end
  end
end
