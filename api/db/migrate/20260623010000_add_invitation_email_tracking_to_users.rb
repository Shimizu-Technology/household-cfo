class AddInvitationEmailTrackingToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :last_invite_email_sent_by_user, foreign_key: { to_table: :users }, index: true
    add_column :users, :invitation_email_status, :string, null: false, default: "not_sent"
    add_column :users, :invitation_email_provider_id, :string
    add_column :users, :invitation_email_error, :text
    add_column :users, :last_invite_email_attempted_at, :datetime
    add_column :users, :last_invite_email_sent_at, :datetime
    add_column :users, :invitation_email_delivery_log, :jsonb, null: false, default: []

    add_index :users, :invitation_email_status
    add_check_constraint :users,
      "invitation_email_status IN ('not_sent', 'skipped', 'sent', 'failed')",
      name: "users_invitation_email_status_valid"
  end
end
