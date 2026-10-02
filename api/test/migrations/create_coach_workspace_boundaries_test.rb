# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261002140000_create_coach_workspace_boundaries")

class CreateCoachWorkspaceBoundariesTest < ActiveSupport::TestCase
  test "tenant boundary migration is explicitly irreversible after tenant writes" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      CreateCoachWorkspaceBoundaries.new.down
    end

    assert_includes error.message, "tenant-scoped names"
  end
end
