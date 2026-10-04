class CreateChallengeReminders < ActiveRecord::Migration[8.1]
  def up
    create_table :challenge_reminder_preferences do |t|
      scope_columns(t)
      t.string :channel, null: false
      t.boolean :enabled, null: false
      t.string :local_time, null: false, default: "18:00"
      t.string :quiet_start, null: false, default: "21:00"
      t.string :quiet_end, null: false, default: "08:00"
      t.string :policy_version, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :challenge_reminder_preferences, [ :savings_enrollment_id, :channel ], unique: true, name: "challenge_reminder_preference_identity"
    create_table :challenge_reminders do |t|
      scope_columns(t)
      t.references :challenge_reminder_preference, null: false, foreign_key: true
      t.string :channel, null: false
      t.date :local_on, null: false
      t.string :status, null: false, default: "pending"
      t.string :reason_code, null: false, default: "scheduled"
      t.string :delivery_key, null: false
      t.datetime :next_attempt_at, null: false
      t.datetime :lease_expires_at
      t.string :lease_token
      t.boolean :provider_idempotent, null: false, default: false
      t.string :provider_namespace
      t.boolean :delivery_uncertain, null: false, default: false
      t.integer :attempts, null: false, default: 0
      t.datetime :delivered_at
      t.datetime :dismissed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :challenge_reminders, [ :savings_enrollment_id, :local_on, :channel ], unique: true, name: "challenge_reminder_day_identity"
    add_index :challenge_reminders, :delivery_key, unique: true
    add_index :challenge_reminders, [ :status, :next_attempt_at ], name: "challenge_reminder_due"
    add_check_constraint :challenge_reminders, "status IN ('pending','leased','delivered','cancelled','failed','unknown') AND attempts >= 0 AND attempts <= 5", name: "challenge_reminder_state"
    add_check_constraint :challenge_reminders, "(status = 'leased' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL) OR (status <> 'leased' AND lease_token IS NULL AND lease_expires_at IS NULL)", name: "challenge_reminder_lease"
    create_table :challenge_reminder_events do |t|
      scope_columns(t)
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.jsonb :approved_values, null: false, default: {}
      t.datetime :created_at, null: false
    end
    execute "CREATE TRIGGER challenge_reminder_events_immutable BEFORE UPDATE OR DELETE ON challenge_reminder_events FOR EACH ROW EXECUTE FUNCTION source_review_facts_immutable()"
    %w[challenge_reminder_preferences challenge_reminders challenge_reminder_events].each do |table|
      execute "CREATE TRIGGER #{table}_scope BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION challenge_privacy_scope_guard()"
    end
    %w[challenge_reminder_preferences challenge_reminders].each do |table|
      add_check_constraint table, "channel IN ('in_app','email')", name: "#{table}_channel"
    end
    add_check_constraint :challenge_reminder_preferences, "local_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' AND quiet_start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' AND quiet_end ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'", name: "challenge_reminder_clock"
    execute <<~SQL
      CREATE FUNCTION challenge_reminder_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_TABLE_NAME = 'challenge_reminder_preferences' THEN
          IF TG_OP = 'UPDATE' AND NEW.channel IS DISTINCT FROM OLD.channel THEN RAISE EXCEPTION 'reminder channel is immutable'; END IF;
        ELSE
          IF NOT EXISTS (SELECT 1 FROM challenge_reminder_preferences p WHERE p.id = NEW.challenge_reminder_preference_id AND p.savings_enrollment_id = NEW.savings_enrollment_id AND p.channel = NEW.channel) THEN RAISE EXCEPTION 'reminder preference scope mismatch'; END IF;
          IF TG_OP = 'UPDATE' AND (NEW.channel, NEW.local_on, NEW.delivery_key, NEW.challenge_reminder_preference_id) IS DISTINCT FROM (OLD.channel, OLD.local_on, OLD.delivery_key, OLD.challenge_reminder_preference_id) THEN RAISE EXCEPTION 'reminder delivery identity is immutable'; END IF;
          IF TG_OP = 'UPDATE' AND OLD.status IN ('delivered','cancelled','failed','unknown') AND NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'terminal reminder cannot be resent'; END IF;
          IF TG_OP = 'UPDATE' AND OLD.provider_namespace IS NOT NULL AND (NEW.provider_namespace, NEW.provider_idempotent) IS DISTINCT FROM (OLD.provider_namespace, OLD.provider_idempotent) THEN RAISE EXCEPTION 'provider delivery identity is immutable'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
    SQL
    %w[challenge_reminder_preferences challenge_reminders].each do |table|
      execute "CREATE TRIGGER #{table}_identity BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION challenge_reminder_identity_guard()"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Reminder decisions and delivery history must be preserved" if %w[challenge_reminder_events challenge_reminders challenge_reminder_preferences].any? { |table| select_value("SELECT EXISTS (SELECT 1 FROM #{table})") }
    %w[challenge_reminder_events challenge_reminders challenge_reminder_preferences].each { |table| drop_table table }
    execute "DROP FUNCTION challenge_reminder_identity_guard()"
  end

  private

  def scope_columns(table)
    table.references :household, null: false, foreign_key: true
    table.references :savings_enrollment, null: false, foreign_key: true
    table.references :participant_user, null: false, foreign_key: { to_table: :users }
  end
end
