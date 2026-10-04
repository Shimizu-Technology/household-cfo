class PinSavingsEnrollmentRelease < ActiveRecord::Migration[8.1]
  def up
    # Preserve any older records without inventing an acceptance-time release.
    # New enrollment must pin a real release; unpinned records fail access checks.
    add_reference :savings_enrollments, :accepted_cohort_release, foreign_key: { to_table: :cohort_releases }
    execute <<~SQL
      CREATE FUNCTION savings_enrollment_release_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE' AND NEW.accepted_cohort_release_id IS DISTINCT FROM OLD.accepted_cohort_release_id THEN
          RAISE EXCEPTION 'accepted savings release is frozen';
        END IF;
        IF TG_OP = 'INSERT' AND (NEW.accepted_cohort_release_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM cohort_releases r WHERE r.id = NEW.accepted_cohort_release_id AND r.cohort_id = NEW.cohort_id
            AND r.tool_registry_version >= 3
            AND r.experience_snapshot->'config'->>'experience_mode' = 'savings_challenge'
        )) THEN RAISE EXCEPTION 'accepted savings release must match the challenge cohort'; END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER savings_enrollments_release BEFORE INSERT OR UPDATE ON savings_enrollments
        FOR EACH ROW EXECUTE FUNCTION savings_enrollment_release_guard();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Accepted savings release history must be preserved"
  end
end
