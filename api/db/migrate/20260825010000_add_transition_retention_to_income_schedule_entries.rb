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
    current_date = Time.current.in_time_zone("Pacific/Guam").to_date

    execute <<~SQL.squish
      WITH effective_changes AS (
        SELECT
          income_schedule_entries.id,
          income_schedule_entries.amount_cents,
          income_schedule_entries.cadence,
          income_sources.amount_cents AS original_amount_cents,
          income_sources.cadence AS original_cadence,
          LAG(income_schedule_entries.amount_cents) OVER source_schedule AS previous_amount_cents,
          LAG(income_schedule_entries.cadence) OVER source_schedule AS previous_cadence,
          ROW_NUMBER() OVER (
            PARTITION BY income_sources.id
            ORDER BY income_schedule_entries.effective_on DESC, income_schedule_entries.id DESC
          ) AS recency
        FROM income_schedule_entries
        INNER JOIN income_sources ON income_sources.id = income_schedule_entries.income_source_id
        INNER JOIN households ON households.id = income_sources.household_id
        WHERE income_sources.active IS TRUE
          AND income_sources.source_type = 'job'
          AND income_schedule_entries.entry_type = 'recurring_change'
          AND income_schedule_entries.effective_on <= #{connection.quote(current_date.end_of_month)}
          AND (
            households.primary_goal ~* '(^|[^a-z])(part[ -]?time|hybrid)([^a-z]|$)'
            OR households.primary_goal ~* 'reduc(e|ed|ing).{0,30}hours?'
            OR households.primary_goal ~* 'cut(ting)?.{0,30}hours?'
            OR households.primary_goal ~* 'scal(e|ing)[[:space:]]+back.{0,30}(hours?|shifts?)'
          )
          AND households.primary_goal !~* '(^|[^a-z])(leave|leaving|quit|quitting|resign|resigning|retire|retiring|exit|exiting)([^a-z]|$)'
          AND households.primary_goal !~* 'stop[[:space:]]+working'
        WINDOW source_schedule AS (
          PARTITION BY income_sources.id
          ORDER BY income_schedule_entries.effective_on, income_schedule_entries.id
        )
      ), normalized_changes AS (
        SELECT
          effective_changes.*,
          #{annualized_amount_sql("effective_changes.amount_cents", "effective_changes.cadence")} AS current_annual_cents,
          #{annualized_amount_sql(
            "COALESCE(effective_changes.previous_amount_cents, effective_changes.original_amount_cents)",
            "COALESCE(effective_changes.previous_cadence, effective_changes.original_cadence)"
          )} AS previous_annual_cents
        FROM effective_changes
        WHERE effective_changes.recency = 1
      )
      UPDATE income_schedule_entries
      SET retained_after_transition = TRUE
      FROM normalized_changes
      WHERE income_schedule_entries.id = normalized_changes.id
        AND income_schedule_entries.amount_cents > 0
        AND income_schedule_entries.retained_after_transition IS NULL
        AND normalized_changes.current_annual_cents < normalized_changes.previous_annual_cents
    SQL
  end

  def annualized_amount_sql(amount, cadence)
    <<~SQL.squish
      CASE #{cadence}
        WHEN 'weekly' THEN #{amount}::bigint * 52
        WHEN 'biweekly' THEN #{amount}::bigint * 26
        WHEN 'semi_monthly' THEN #{amount}::bigint * 24
        WHEN 'annual' THEN #{amount}::bigint
        ELSE #{amount}::bigint * 12
      END
    SQL
  end
end
