class PreserveUnlinkedHouseholdRecordTransfers < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION financial_picture_write_guard() RETURNS trigger AS $$
      DECLARE current_generation integer;
      BEGIN
        SELECT financial_generation INTO current_generation FROM households WHERE id = NEW.household_id FOR UPDATE;
        IF NEW.financial_generation IS DISTINCT FROM current_generation THEN
          RAISE EXCEPTION 'financial_generation_stale: reload the current financial picture' USING ERRCODE = '23514';
        END IF;
        IF TG_OP = 'UPDATE' AND TG_TABLE_NAME <> 'household_profiles' AND NEW.financial_generation IS DISTINCT FROM OLD.financial_generation THEN
          RAISE EXCEPTION 'financial picture generation cannot change' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Generation protection remains required after financial restart"
  end
end
