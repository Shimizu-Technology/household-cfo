# frozen_string_literal: true

class HardenWorkspaceDomainIdentity < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE FUNCTION prevent_verified_workspace_domain_identity_change()
      RETURNS trigger AS $$
      BEGIN
        IF (NEW.hostname IS DISTINCT FROM OLD.hostname OR NEW.kind IS DISTINCT FROM OLD.kind)
          AND (
            OLD.verification_requested_at IS NOT NULL
            OR OLD.verified_at IS NOT NULL
            OR OLD.activated_at IS NOT NULL
            OR OLD.status <> 'pending'
          )
        THEN
          RAISE EXCEPTION 'verified workspace domain identity cannot change';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER coach_workspace_domains_verified_identity
      BEFORE UPDATE ON coach_workspace_domains
      FOR EACH ROW EXECUTE FUNCTION prevent_verified_workspace_domain_identity_change();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS coach_workspace_domains_verified_identity ON coach_workspace_domains"
    execute "DROP FUNCTION IF EXISTS prevent_verified_workspace_domain_identity_change()"
  end
end
