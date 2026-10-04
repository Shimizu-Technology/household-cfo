# frozen_string_literal: true

class ProtectCoachWorkspaceMembershipEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    connection.transaction do
      %w[before_role after_role].each do |column|
        next if check_constraint_exists?(:coach_workspace_membership_events, name: "workspace_membership_event_#{column}")

        add_check_constraint :coach_workspace_membership_events,
          "#{column} IS NULL OR #{column} IN ('owner', 'editor', 'reviewer', 'viewer')",
          name: "workspace_membership_event_#{column}", validate: false
      end
      execute <<~SQL
        CREATE OR REPLACE FUNCTION prevent_workspace_membership_event_mutation()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'collaborator access history cannot be changed or deleted'
            USING ERRCODE = 'integrity_constraint_violation';
        END;
        $$;
        DROP TRIGGER IF EXISTS workspace_membership_events_immutable ON coach_workspace_membership_events;
        CREATE TRIGGER workspace_membership_events_immutable
          BEFORE UPDATE OR DELETE ON coach_workspace_membership_events
          FOR EACH ROW EXECUTE FUNCTION prevent_workspace_membership_event_mutation();
      SQL
    end
    %w[before_role after_role].each do |column|
      validate_check_constraint :coach_workspace_membership_events, name: "workspace_membership_event_#{column}"
    end
  end

  def down
    connection.transaction do
      execute "DROP TRIGGER workspace_membership_events_immutable ON coach_workspace_membership_events"
      execute "DROP FUNCTION prevent_workspace_membership_event_mutation()"
      %w[before_role after_role].each do |column|
        remove_check_constraint :coach_workspace_membership_events, name: "workspace_membership_event_#{column}"
      end
    end
  end
end
