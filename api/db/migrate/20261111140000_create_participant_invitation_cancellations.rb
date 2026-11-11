# frozen_string_literal: true

# A program owner cancelling a pending invitation is access history: who did it, to whom, for which groups.
class CreateParticipantInvitationCancellations < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_invitation_cancellations do |t|
      t.references :coach_workspace, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :subject_user, null: false, foreign_key: { to_table: :users }
      t.string :subject_email, null: false
      t.jsonb :groups, null: false, default: []
      t.datetime :created_at, null: false
    end
  end
end
