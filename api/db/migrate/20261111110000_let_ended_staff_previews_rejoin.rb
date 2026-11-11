# A staff member's challenge preview ends as a withdrawal and its row stays as
# history. That row must not stop the same person joining the challenge for real
# later (a coach added as a participant) or taking a fresh preview.
#
# `staff_preview` marks an enrollment accepted through a preview seat. The unique
# index on (cohort, user) now ignores only a withdrawn staff preview, so everyone
# else keeps exactly one enrollment per group, and a withdrawn participant
# enrollment still cannot be replaced. The ledgers that point at an enrollment
# are untouched: the old preview enrollment keeps its id and its rows.
class LetEndedStaffPreviewsRejoin < ActiveRecord::Migration[8.0]
  INDEX = "index_savings_enrollments_on_cohort_id_and_user_id"

  def up
    add_column :savings_enrollments, :staff_preview, :boolean, null: false, default: false
    execute <<~SQL.squish
      UPDATE savings_enrollments SET staff_preview = TRUE
      WHERE accepted_cohort_membership_id IN (SELECT id FROM cohort_memberships WHERE role IN ('preview', 'preview_ended'))
    SQL
    remove_index :savings_enrollments, name: INDEX
    add_index :savings_enrollments, %i[cohort_id user_id], unique: true, name: INDEX,
      where: "NOT (staff_preview AND status = 'withdrawn')"
  end

  def down
    if select_value("SELECT 1 FROM savings_enrollments WHERE staff_preview LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Staff challenge previews exist. Removing staff_preview would count them as participants."
    end

    remove_index :savings_enrollments, name: INDEX
    add_index :savings_enrollments, %i[cohort_id user_id], unique: true, name: INDEX
    remove_column :savings_enrollments, :staff_preview
  end
end
