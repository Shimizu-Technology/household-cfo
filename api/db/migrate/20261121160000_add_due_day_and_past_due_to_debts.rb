# frozen_string_literal: true


class AddDueDayAndPastDueToDebts < ActiveRecord::Migration[8.0]
  # Both stay NULL until she enters them: a blank past-due amount means "not entered",
  # never "$0 behind", and a blank due day means the lender's date is not recorded.
  def change
    add_column :debts, :due_day, :integer
    add_column :debts, :past_due_cents, :bigint
    add_check_constraint :debts, "due_day IS NULL OR due_day BETWEEN 1 AND 31", name: "debts_due_day_valid"
    add_check_constraint :debts, "past_due_cents IS NULL OR past_due_cents >= 0", name: "debts_past_due_cents_non_negative"
  end
end
