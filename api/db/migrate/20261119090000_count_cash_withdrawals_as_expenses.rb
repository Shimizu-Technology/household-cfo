class CountCashWithdrawalsAsExpenses < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT = "source_event_expense_eligible".freeze
  REPLACEMENT = "source_event_expense_eligible_cash".freeze
  OLD_RULE = "expense_amount_cents IS NULL OR (row_kind = 'posted' AND event_type IN ('purchase', 'fee', 'interest') AND signed_amount_cents < 0 AND posted_on IS NOT NULL)".freeze
  NEW_RULE = "expense_amount_cents IS NULL OR (row_kind = 'posted' AND event_type IN ('purchase', 'fee', 'interest', 'cash_withdrawal') AND signed_amount_cents < 0 AND posted_on IS NOT NULL)".freeze
  BATCH_SIZE = 250
  ELIGIBLE = "row_kind = 'posted' AND event_type = 'cash_withdrawal' AND signed_amount_cents < 0 AND posted_on IS NOT NULL AND limitations = '[]'::jsonb AND expense_amount_cents IS NULL".freeze

  def up
    add_check_constraint :financial_source_events, NEW_RULE, name: REPLACEMENT, validate: false unless check_constraint_exists?(:financial_source_events, name: REPLACEMENT)
    validate_check_constraint :financial_source_events, name: REPLACEMENT
    # Constraint DDL holds ACCESS EXCLUSIVE only for short catalog operations;
    # validation and backfill run outside those transactions.
    connection.transaction do
      remove_check_constraint :financial_source_events, name: CONSTRAINT
      execute "ALTER TABLE financial_source_events RENAME CONSTRAINT #{REPLACEMENT} TO #{CONSTRAINT}"
    end

    loop do
      ids = connection.select_values("SELECT id FROM financial_source_events WHERE #{ELIGIBLE} ORDER BY id LIMIT #{BATCH_SIZE}")
      break if ids.empty?

      connection.transaction do
        # Trigger suspension requires SHARE ROW EXCLUSIVE. Reads remain available;
        # concurrent writers wait only for this batch and cannot bypass immutability.
        # A failure rolls back both the batch and trigger suspension together.
        execute "LOCK TABLE financial_source_events IN SHARE ROW EXCLUSIVE MODE"
        execute "ALTER TABLE financial_source_events DISABLE TRIGGER financial_source_events_immutable"
        execute "UPDATE financial_source_events SET expense_amount_cents = ABS(signed_amount_cents) WHERE id IN (#{ids.map { |id| Integer(id) }.join(',')}) AND #{ELIGIBLE}"
        execute "ALTER TABLE financial_source_events ENABLE TRIGGER financial_source_events_immutable"
      end
    end
  end

  def down
    connection.transaction do
      # Keep the guard and constraint swap atomic against concurrent inserts.
      execute "LOCK TABLE financial_source_events IN ACCESS EXCLUSIVE MODE"
      if connection.select_value("SELECT 1 FROM financial_source_events WHERE event_type = 'cash_withdrawal' AND expense_amount_cents IS NOT NULL LIMIT 1")
        raise ActiveRecord::IrreversibleMigration, "Cash withdrawal expense amounts exist; preserve participant-approved spending"
      end
      remove_check_constraint :financial_source_events, name: CONSTRAINT
      add_check_constraint :financial_source_events, OLD_RULE, name: CONSTRAINT, validate: false
    end
    validate_check_constraint :financial_source_events, name: CONSTRAINT
  end
end
