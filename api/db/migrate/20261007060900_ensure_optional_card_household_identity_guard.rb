class EnsureOptionalCardHouseholdIdentityGuard < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.debts_optional_card_identity_guard()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
      BEGIN
        IF NEW.household_id IS DISTINCT FROM OLD.household_id THEN
          PERFORM 1 FROM households WHERE id=OLD.household_id FOR UPDATE;
          IF (
            EXISTS (SELECT 1 FROM savings_debt_cards WHERE household_debt_id=OLD.id) OR
            EXISTS (SELECT 1 FROM savings_debt_drafts WHERE household_debt_id=OLD.id) OR
            EXISTS (SELECT 1 FROM savings_debt_versions WHERE household_debt_id=OLD.id)
          ) THEN RAISE EXCEPTION 'optional card review history household identity cannot change'; END IF;
        END IF;
        RETURN NEW;
      END; $function$;

      DROP TRIGGER IF EXISTS debts_optional_card_identity_guard ON public.debts;
      CREATE TRIGGER debts_optional_card_identity_guard BEFORE UPDATE OF household_id ON public.debts FOR EACH ROW EXECUTE FUNCTION debts_optional_card_identity_guard();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Optional card review history must retain its household identity guard"
  end
end
