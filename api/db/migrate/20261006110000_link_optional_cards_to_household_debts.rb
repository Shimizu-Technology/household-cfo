class LinkOptionalCardsToHouseholdDebts < ActiveRecord::Migration[8.1]
  def up
    add_reference :savings_debt_cards, :household_debt, foreign_key: { to_table: :debts }
    add_index :savings_debt_cards, [ :savings_enrollment_id, :household_debt_id ], unique: true, where: "household_debt_id IS NOT NULL", name: "savings_debt_household_identity_once"
    %i[savings_debt_drafts savings_debt_versions].each do |table|
      add_reference table, :household_debt, foreign_key: { to_table: :debts }
      add_column table, :household_debt_fingerprint, :string
      add_column table, :household_debt_snapshot, :jsonb, default: {}, null: false
      add_check_constraint table, "(household_debt_id IS NULL AND household_debt_fingerprint IS NULL AND household_debt_snapshot = '{}'::jsonb) OR (household_debt_id IS NOT NULL AND household_debt_fingerprint IS NOT NULL AND household_debt_fingerprint ~ '^[0-9a-f]{64}$' AND jsonb_typeof(household_debt_snapshot) = 'object' AND household_debt_snapshot ? 'id' AND household_debt_snapshot->'id' = to_jsonb(household_debt_id))", name: "#{table}_household_link_complete"
    end
    execute <<~SQL
      CREATE FUNCTION savings_debt_household_link_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE card savings_debt_cards; version savings_debt_versions; debt debts;
      BEGIN
        IF TG_TABLE_NAME='savings_debt_cards' THEN
          card := NEW;
          IF NEW.current_version_id IS NOT NULL THEN
            SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.current_version_id;
            IF NEW.household_debt_id IS DISTINCT FROM version.household_debt_id THEN RAISE EXCEPTION 'card household link must match approved version'; END IF;
          ELSIF NEW.household_debt_id IS NOT NULL THEN RAISE EXCEPTION 'card household link requires approved terms'; END IF;
        ELSE
          SELECT * INTO STRICT card FROM savings_debt_cards WHERE id=NEW.savings_debt_card_id;
          IF TG_TABLE_NAME='savings_debt_drafts' AND TG_OP='UPDATE' THEN
            SELECT * INTO STRICT version FROM savings_debt_versions WHERE id=NEW.approved_version_id;
            IF ROW(NEW.household_debt_id,NEW.household_debt_fingerprint,NEW.household_debt_snapshot) IS DISTINCT FROM ROW(version.household_debt_id,version.household_debt_fingerprint,version.household_debt_snapshot) THEN RAISE EXCEPTION 'approved household link does not match draft'; END IF;
          END IF;
        END IF;
        IF NEW.household_debt_id IS NOT NULL THEN
          SELECT * INTO STRICT debt FROM debts WHERE id=NEW.household_debt_id;
          IF debt.household_id<>card.household_id OR debt.debt_type<>'credit_card' THEN RAISE EXCEPTION 'household card link scope invalid'; END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE FUNCTION debts_optional_card_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
      END; $$;
      CREATE TRIGGER debts_optional_card_identity_guard BEFORE UPDATE OF household_id ON debts FOR EACH ROW EXECUTE FUNCTION debts_optional_card_identity_guard();
      CREATE TRIGGER savings_debt_cards_household_link_guard BEFORE INSERT OR UPDATE ON savings_debt_cards FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
      CREATE TRIGGER savings_debt_drafts_household_link_guard BEFORE INSERT OR UPDATE ON savings_debt_drafts FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
      CREATE TRIGGER savings_debt_versions_household_link_guard BEFORE INSERT OR UPDATE ON savings_debt_versions FOR EACH ROW EXECUTE FUNCTION savings_debt_household_link_guard();
    SQL
  end

  def down
    execute "LOCK TABLE savings_debt_cards,savings_debt_drafts,savings_debt_versions IN ACCESS EXCLUSIVE MODE"
    raise ActiveRecord::IrreversibleMigration, "Reviewed household card links must be retained" if select_value("SELECT EXISTS (SELECT 1 FROM savings_debt_versions WHERE household_debt_id IS NOT NULL UNION ALL SELECT 1 FROM savings_debt_drafts WHERE household_debt_id IS NOT NULL)")
    %i[savings_debt_cards savings_debt_drafts savings_debt_versions].each { |table| execute "DROP TRIGGER #{table}_household_link_guard ON #{table}" }
    execute "DROP TRIGGER IF EXISTS debts_optional_card_identity_guard ON debts"
    execute "DROP FUNCTION IF EXISTS debts_optional_card_identity_guard()"
    execute "DROP FUNCTION savings_debt_household_link_guard()"
    remove_index :savings_debt_cards, name: "savings_debt_household_identity_once"
    %i[savings_debt_drafts savings_debt_versions].each do |table|
      remove_check_constraint table, name: "#{table}_household_link_complete"
      remove_column table, :household_debt_snapshot
      remove_column table, :household_debt_fingerprint
      remove_reference table, :household_debt, foreign_key: { to_table: :debts }
    end
    remove_reference :savings_debt_cards, :household_debt, foreign_key: { to_table: :debts }
  end
end
