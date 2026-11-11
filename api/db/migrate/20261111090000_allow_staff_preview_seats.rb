# frozen_string_literal: true

# Staff (admins and coaches) use the same app a participant does. When they try a
# group out they hold a "preview" seat: a cohort membership with its own role, so
# every query that asks for participants leaves them out unless it opts in.
#
# - the role check accepts "preview", and "preview_ended" for a left seat that an
#   enrollment still points at;
# - a person may now hold one row per role in a cohort (a coach can also preview
#   the group they coach);
# - the optional-debt scope guard stops insisting that the enrolled user's global
#   role is "participant" and instead accepts the preview seat the enrollment was
#   accepted through.
class AllowStaffPreviewSeats < ActiveRecord::Migration[8.0]
  GUARD = "savings_debt_scope_guard()"
  OLD_CHECK = "role='participant' AND invitation_status<>'revoked'"
  NEW_CHECK = <<~SQL.squish
    invitation_status<>'revoked' AND (role='participant' OR EXISTS (SELECT 1 FROM cohort_memberships preview_seat WHERE preview_seat.id=enrollment.accepted_cohort_membership_id AND preview_seat.user_id=users.id AND preview_seat.role='preview'))
  SQL

  def up
    remove_check_constraint :cohort_memberships, name: "cohort_memberships_role_valid"
    add_check_constraint :cohort_memberships,
      "role IN ('participant', 'coach', 'admin', 'preview', 'preview_ended')", name: "cohort_memberships_role_valid"
    remove_index :cohort_memberships, name: "index_cohort_memberships_on_cohort_id_and_user_id"
    add_index :cohort_memberships, %i[cohort_id user_id role], unique: true,
      name: "index_cohort_memberships_on_cohort_id_and_user_id_and_role"
    replace_guard(OLD_CHECK, NEW_CHECK)
  end

  # Old code reads every enrollment of a cohort as a participant's. Rolling back
  # while any preview data exists would make staff previews count in rosters,
  # caps, sponsor reports and reminders, and a person may now hold two roles in
  # one group, which the old unique index refuses. So this only runs on a clean DB.
  # (A preview enrollment is also caught earlier, by the next migration's down.)
  def down
    unless select_value("SELECT 1 FROM cohort_memberships WHERE role IN ('preview', 'preview_ended') LIMIT 1").nil?
      raise ActiveRecord::IrreversibleMigration, "Preview seats exist. Rolling back would count staff previews as participants."
    end
    unless select_value("SELECT 1 FROM cohort_memberships GROUP BY cohort_id, user_id HAVING COUNT(*) > 1 LIMIT 1").nil?
      raise ActiveRecord::IrreversibleMigration, "A person holds more than one role in a group. The old unique index would refuse it."
    end

    replace_guard(NEW_CHECK, OLD_CHECK)
    remove_index :cohort_memberships, name: "index_cohort_memberships_on_cohort_id_and_user_id_and_role"
    add_index :cohort_memberships, %i[cohort_id user_id], unique: true,
      name: "index_cohort_memberships_on_cohort_id_and_user_id"
    remove_check_constraint :cohort_memberships, name: "cohort_memberships_role_valid"
    add_check_constraint :cohort_memberships,
      "role IN ('participant', 'coach', 'admin')", name: "cohort_memberships_role_valid"
  end

  private

  def replace_guard(from, to)
    definition = select_value("SELECT pg_get_functiondef(to_regprocedure('#{GUARD}'))")
    return if definition.blank?
    raise "savings_debt_scope_guard no longer has the expected participant check" unless definition.include?(from)

    execute definition.sub(from, to)
  end
end
