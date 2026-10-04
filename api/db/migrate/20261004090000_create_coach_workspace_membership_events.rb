class CreateCoachWorkspaceMembershipEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :coach_workspace_membership_events do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :subject_user, null: false, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.string :before_role
      t.string :after_role
      t.timestamps
    end
    add_check_constraint :coach_workspace_membership_events, "event_type IN ('added', 'role_changed', 'removed')", name: "workspace_membership_event_type"
  end
end
