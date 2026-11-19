class CountCashWithdrawalsAsExpenses < ActiveRecord::Migration[8.1]
  def up
    # Rails runs this migration in one transaction; the table lock keeps the
    # temporary trigger suspension private to this narrowly scoped backfill.
    execute "LOCK TABLE financial_source_events IN ACCESS EXCLUSIVE MODE"
    remove_check_constraint :financial_source_events, name: "source_event_expense_eligible"
    add_check_constraint :financial_source_events,
      "expense_amount_cents IS NULL OR (row_kind = 'posted' AND event_type IN ('purchase', 'fee', 'interest', 'cash_withdrawal') AND signed_amount_cents < 0 AND posted_on IS NOT NULL)",
      name: "source_event_expense_eligible"

    execute "ALTER TABLE financial_source_events DISABLE TRIGGER financial_source_events_immutable"
    execute <<~SQL
      UPDATE financial_source_events
      SET expense_amount_cents = ABS(signed_amount_cents)
      WHERE row_kind = 'posted' AND event_type = 'cash_withdrawal'
        AND signed_amount_cents < 0 AND posted_on IS NOT NULL
        AND limitations = '[]'::jsonb AND expense_amount_cents IS NULL
    SQL
    execute "ALTER TABLE financial_source_events ENABLE TRIGGER financial_source_events_immutable"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Cash withdrawal expense amounts may already have participant-approved spending; do not erase them"
  end
end
