class AddSavingsPlanContext < ActiveRecord::Migration[8.1]
  def up
    %i[savings_plan_drafts savings_plan_versions].each do |table|
      add_reference table, :financial_baseline_version, foreign_key: true
      add_column table, :baseline_digest, :string
      add_column table, :spending_changes, :jsonb, null: false, default: []
      add_check_constraint table, "jsonb_typeof(spending_changes) = 'array' AND jsonb_array_length(spending_changes) <= 5 AND ((financial_baseline_version_id IS NULL AND baseline_digest IS NULL) OR (financial_baseline_version_id IS NOT NULL AND baseline_digest ~ '^[0-9a-f]{64}$'))", name: "#{table}_context_valid"
    end
    execute <<~SQL
      CREATE FUNCTION savings_plan_context_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.financial_baseline_version_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM financial_baseline_versions v JOIN financial_baseline_heads h ON h.id = v.financial_baseline_head_id
          JOIN savings_enrollments e ON e.id = NEW.savings_enrollment_id
          WHERE v.id = NEW.financial_baseline_version_id AND v.household_id = e.household_id AND h.participant_user_id = e.user_id AND v.digest = NEW.baseline_digest
        ) THEN RAISE EXCEPTION 'plan baseline participant boundary'; END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER savings_plan_drafts_context BEFORE INSERT OR UPDATE ON savings_plan_drafts FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
      CREATE TRIGGER savings_plan_versions_context BEFORE INSERT ON savings_plan_versions FOR EACH ROW EXECUTE FUNCTION savings_plan_context_guard();
    SQL
  end

  def down
    %w[savings_plan_drafts savings_plan_versions].each do |table|
      raise ActiveRecord::IrreversibleMigration, "Approved plan context must be retained" if select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE financial_baseline_version_id IS NOT NULL OR spending_changes <> '[]'::jsonb)")
      execute "DROP TRIGGER #{table}_context ON #{table}"
      remove_check_constraint table, name: "#{table}_context_valid"
      remove_reference table, :financial_baseline_version, foreign_key: true
      remove_column table, :baseline_digest
      remove_column table, :spending_changes
    end
    execute "DROP FUNCTION savings_plan_context_guard()"
  end
end
