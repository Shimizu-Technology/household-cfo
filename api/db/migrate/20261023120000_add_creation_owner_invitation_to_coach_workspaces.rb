# frozen_string_literal: true

class AddCreationOwnerInvitationToCoachWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :coach_workspaces, :creation_owner_invitation, :jsonb
  end
end
