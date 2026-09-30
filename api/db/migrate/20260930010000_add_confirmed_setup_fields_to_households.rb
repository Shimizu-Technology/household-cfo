class AddConfirmedSetupFieldsToHouseholds < ActiveRecord::Migration[8.1]
  def up
    add_column :households, :confirmed_setup_fields, :jsonb, default: [], null: false
    execute <<~SQL.squish
      UPDATE households AS household
      SET confirmed_setup_fields = (
        SELECT COALESCE(jsonb_agg(candidate.field ORDER BY candidate.position), '[]'::jsonb)
        FROM (
          VALUES
            (1, 'household_name', NULLIF(BTRIM(household.name), '') IS NOT NULL),
            (2, 'primary_goal', NULLIF(BTRIM(household.primary_goal), '') IS NOT NULL),
            (3, 'primary_income', EXISTS (
              SELECT 1 FROM income_sources
              WHERE income_sources.household_id = household.id AND income_sources.source_type = 'job'
            )),
            (4, 'fixed_expenses', EXISTS (
              SELECT 1 FROM expense_items
              WHERE expense_items.household_id = household.id AND expense_items.stack_key = 'non_discretionary'
            )),
            (5, 'flexible_spend', EXISTS (
              SELECT 1 FROM expense_items
              WHERE expense_items.household_id = household.id AND expense_items.stack_key = 'discretionary'
            ))
        ) AS candidate(position, field, confirmed)
        WHERE candidate.confirmed
      )
    SQL
    add_check_constraint :households,
      "jsonb_typeof(confirmed_setup_fields) = 'array'",
      name: "households_confirmed_setup_fields_array"
  end

  def down
    remove_check_constraint :households, name: "households_confirmed_setup_fields_array"
    remove_column :households, :confirmed_setup_fields
  end
end
