class AddTransitionRetentionToIncomeScheduleEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :income_schedule_entries, :retained_after_transition, :boolean
    add_check_constraint :income_schedule_entries,
                         "retained_after_transition IS NOT TRUE OR (entry_type = 'recurring_change' AND amount_cents > 0)",
                         name: "income_schedule_entries_retained_income_valid"
  end
end
