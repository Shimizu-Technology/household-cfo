# frozen_string_literal: true

# A left preview seat stays as a `preview_ended` row when a challenge enrollment still
# points at it. Someone who previews a challenge group, leaves, previews again and leaves
# again then has two such rows in the same group, and the unique index on
# (cohort, user, role) refused the second one. That blocked leaving, demoting, revoking and
# archiving.
#
# The index now ignores `preview_ended` rows: ended seats are history, any number may exist
# beside each other, and every other role keeps exactly one row per person and group. Each
# ended row keeps its own id, so the enrollment pointing at it stays valid.
class AllowManyEndedPreviewSeats < ActiveRecord::Migration[8.0]
  INDEX = "index_cohort_memberships_on_cohort_id_and_user_id_and_role"

  def up
    remove_index :cohort_memberships, name: INDEX
    add_index :cohort_memberships, %i[cohort_id user_id role], unique: true, name: INDEX,
      where: "role <> 'preview_ended'"
  end

  def down
    unless select_value("SELECT 1 FROM cohort_memberships WHERE role = 'preview_ended' GROUP BY cohort_id, user_id HAVING COUNT(*) > 1 LIMIT 1").nil?
      raise ActiveRecord::IrreversibleMigration, "A person has several ended preview seats in one group. The full unique index would refuse them."
    end

    remove_index :cohort_memberships, name: INDEX
    add_index :cohort_memberships, %i[cohort_id user_id role], unique: true, name: INDEX
  end
end
