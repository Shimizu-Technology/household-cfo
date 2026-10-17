# frozen_string_literal: true

# Marks coach rows that were granted automatically because the user owns the
# program, so demoting the owner removes exactly those rows and leaves any
# manually assigned coach rows alone.
class AddOwnerManagedToCohortMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :cohort_memberships, :owner_managed, :boolean, null: false, default: false
  end
end
