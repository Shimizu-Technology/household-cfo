class AddMiaPersonalizationControlsToHouseholdMemberships < ActiveRecord::Migration[8.0]
  def change
    add_column :household_memberships, :mia_personalization_paused, :boolean, null: false, default: false
    add_column :household_memberships, :mia_personalization_paused_at, :datetime
  end
end
