class RequireGoalSourceMetadataObject < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :goals, "jsonb_typeof(source_metadata) = 'object'",
      name: "goals_source_metadata_object"
  end
end
