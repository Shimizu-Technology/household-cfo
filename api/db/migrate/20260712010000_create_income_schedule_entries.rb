class CreateIncomeScheduleEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :income_schedule_entries do |t|
      t.references :income_source, null: false, foreign_key: { on_delete: :cascade }
      t.string :entry_type, null: false, default: "recurring_change"
      t.string :label
      t.integer :amount_cents, null: false, default: 0
      t.string :cadence, null: false, default: "monthly"
      t.date :effective_on, null: false

      t.timestamps
    end

    add_index :income_schedule_entries, [ :income_source_id, :effective_on ],
      unique: true,
      where: "entry_type = 'recurring_change'",
      name: "index_income_schedule_entries_on_recurring_source_and_date"
    add_check_constraint :income_schedule_entries, "amount_cents >= 0",
      name: "income_schedule_entries_amount_cents_non_negative"
    add_check_constraint :income_schedule_entries,
      "entry_type IN ('recurring_change', 'one_time')",
      name: "income_schedule_entries_type_valid"
  end
end
