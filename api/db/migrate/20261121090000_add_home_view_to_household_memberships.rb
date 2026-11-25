# frozen_string_literal: true

# A person's own choice of what Home leads with (this month or the year). Null follows
# the program's method setting.
class AddHomeViewToHouseholdMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :household_memberships, :home_view, :string
    add_check_constraint :household_memberships, "home_view IS NULL OR home_view IN ('month', 'year')", name: "household_memberships_home_view_valid"
  end
end
