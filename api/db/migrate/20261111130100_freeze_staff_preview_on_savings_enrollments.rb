# frozen_string_literal: true

# `staff_preview` decides whether an enrollment is counted anywhere, and which enrollments
# may be replaced after a withdrawal. Like the rest of an enrollment's identity it must never
# change after creation, or a stray update could drop a real participant out of every count.
class FreezeStaffPreviewOnSavingsEnrollments < ActiveRecord::Migration[8.0]
  GUARD = "savings_identity_guard()"
  OLD_TAIL = "OLD.late_start_accepted) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'"
  NEW_TAIL = "OLD.late_start_accepted,OLD.staff_preview) THEN RAISE EXCEPTION 'savings enrollment identity is frozen'"
  OLD_HEAD = "NEW.late_start_accepted)\n"
  NEW_HEAD = "NEW.late_start_accepted,NEW.staff_preview)\n"

  def up
    replace_guard(OLD_HEAD, NEW_HEAD, OLD_TAIL, NEW_TAIL)
  end

  def down
    replace_guard(NEW_HEAD, OLD_HEAD, NEW_TAIL, OLD_TAIL)
  end

  private

  def replace_guard(from_head, to_head, from_tail, to_tail)
    definition = select_value("SELECT pg_get_functiondef(to_regprocedure('#{GUARD}'))")
    raise "#{GUARD} is missing" if definition.blank?
    unless definition.include?(from_head) && definition.include?(from_tail)
      raise "#{GUARD} no longer has the expected enrollment identity check"
    end

    execute definition.sub(from_head, to_head).sub(from_tail, to_tail)
  end
end
