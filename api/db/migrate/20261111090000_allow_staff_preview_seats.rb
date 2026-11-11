# frozen_string_literal: true

# Staff (admins and coaches) use the same app a participant does. When they try a
# group out they hold a "preview" seat: a cohort membership with its own role, so
# every query that asks for participants leaves them out unless it opts in.
#
# - the role check accepts "preview";
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
      "role IN ('participant', 'coach', 'admin', 'preview')", name: "cohort_memberships_role_valid"
    remove_index :cohort_memberships, name: "index_cohort_memberships_on_cohort_id_and_user_id"
    add_index :cohort_memberships, %i[cohort_id user_id role], unique: true,
      name: "index_cohort_memberships_on_cohort_id_and_user_id_and_role"
    replace_guard(OLD_CHECK, NEW_CHECK)
  end

  def down
    execute "DELETE FROM cohort_memberships WHERE role = 'preview'"
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
