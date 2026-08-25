class AddTransitionRetentionToIncomeScheduleEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :income_schedule_entries, :retained_after_transition, :boolean
    add_check_constraint :income_schedule_entries,
                         "retained_after_transition IS NOT TRUE OR (entry_type = 'recurring_change' AND amount_cents > 0)",
                         name: "income_schedule_entries_retained_income_valid"

    reversible do |direction|
      direction.up { preserve_explicit_reduced_hours_intent }
    end
  end

  private

  def preserve_explicit_reduced_hours_intent
    execute <<~SQL.squish
      UPDATE income_schedule_entries
      SET retained_after_transition = TRUE
      FROM income_sources, households
      WHERE income_schedule_entries.income_source_id = income_sources.id
        AND income_sources.household_id = households.id
        AND income_sources.active IS TRUE
        AND income_sources.source_type = 'job'
        AND income_schedule_entries.entry_type = 'recurring_change'
        AND income_schedule_entries.amount_cents > 0
        AND income_schedule_entries.retained_after_transition IS NULL
        AND (
          households.primary_goal ~* '(^|[^a-z])(part[ -]?time|hybrid)([^a-z]|$)'
          OR households.primary_goal ~* 'reduc(e|ed|ing).{0,30}hours?'
          OR households.primary_goal ~* 'cut(ting)?.{0,30}hours?'
          OR households.primary_goal ~* 'scal(e|ing)[[:space:]]+back.{0,30}(hours?|shifts?)'
        )
        AND households.primary_goal !~* '(^|[^a-z])(leave|leaving|quit|quitting|resign|resigning|retire|retiring|exit|exiting)([^a-z]|$)'
        AND households.primary_goal !~* 'stop[[:space:]]+working'
    SQL
  end
end
