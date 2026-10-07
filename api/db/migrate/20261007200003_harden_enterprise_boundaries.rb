class HardenEnterpriseBoundaries < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION enforce_enterprise_mapping_boundary() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM enterprise_organizations o JOIN cohorts c ON c.coach_workspace_id = o.coach_workspace_id
          WHERE o.id = NEW.enterprise_organization_id AND c.id = NEW.cohort_id
        ) THEN RAISE EXCEPTION 'Enterprise group mapping must remain in its program' USING ERRCODE = '23514'; END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER enterprise_mapping_boundary BEFORE INSERT OR UPDATE ON enterprise_group_mappings
        FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_mapping_boundary();
      CREATE FUNCTION enforce_enterprise_directory_boundary() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.enterprise_membership_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM enterprise_memberships m WHERE m.id = NEW.enterprise_membership_id AND m.enterprise_organization_id = NEW.enterprise_organization_id
        ) THEN RAISE EXCEPTION 'Enterprise directory membership must remain in its organization' USING ERRCODE = '23514'; END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER enterprise_directory_boundary BEFORE INSERT OR UPDATE ON enterprise_directory_users
        FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_directory_boundary();
      CREATE FUNCTION enforce_enterprise_grant_boundary() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM enterprise_memberships m
          JOIN enterprise_organizations o ON o.id = m.enterprise_organization_id
          JOIN cohort_memberships cm ON cm.id = NEW.cohort_membership_id AND cm.user_id = m.user_id AND cm.role = 'participant'
          JOIN cohorts c ON c.id = cm.cohort_id AND c.coach_workspace_id = o.coach_workspace_id
          WHERE m.id = NEW.enterprise_membership_id
        ) THEN RAISE EXCEPTION 'Enterprise grants may only enroll their participant in their program' USING ERRCODE = '23514'; END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER enterprise_grant_boundary BEFORE INSERT OR UPDATE ON enterprise_cohort_grants
        FOR EACH ROW EXECUTE FUNCTION enforce_enterprise_grant_boundary();
    SQL
  end

  def down
    execute "DROP TRIGGER enterprise_grant_boundary ON enterprise_cohort_grants; DROP FUNCTION enforce_enterprise_grant_boundary();"
    execute "DROP TRIGGER enterprise_directory_boundary ON enterprise_directory_users; DROP FUNCTION enforce_enterprise_directory_boundary();"
    execute "DROP TRIGGER enterprise_mapping_boundary ON enterprise_group_mappings; DROP FUNCTION enforce_enterprise_mapping_boundary();"
  end
end
