# frozen_string_literal: true

class AddCoachWorkspaceCreationRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :coach_workspaces, :creation_request_key, :string
    add_column :coach_workspaces, :creation_request_fingerprint, :string
    add_index :coach_workspaces, %i[created_by_user_id creation_request_key], unique: true,
      where: "creation_request_key IS NOT NULL", name: "idx_coach_workspaces_creation_request"
  end
end
