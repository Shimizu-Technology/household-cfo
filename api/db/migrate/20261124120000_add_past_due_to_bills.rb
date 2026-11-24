# How far behind she is on a bill (a utility or phone bill she owes from before), owed now. NULL is not entered,
# never "$0 behind".
class AddPastDueToBills < ActiveRecord::Migration[8.0]
  def change
    add_column :bills, :past_due_cents, :integer
    add_check_constraint :bills, "past_due_cents IS NULL OR past_due_cents >= 0", name: "bills_past_due_cents_non_negative"
  end
end
