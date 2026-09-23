class EnsurePilotFeedbackReportConstraints < ActiveRecord::Migration[8.1]
  WORKFLOW_CONSTRAINT = "pilot_feedback_reports_workflow_valid"
  STATUS_CONSTRAINT = "pilot_feedback_reports_status_valid"
  WORKFLOWS = %w[sign_in home setup ask_mia voice budget transaction_review receipt_upload statement_upload document_upload private_document admin other].freeze
  STATUSES = %w[submitted reviewed resolved].freeze

  def up
    repair_invalid_values!(:workflow, WORKFLOWS, "other")
    repair_invalid_values!(:status, STATUSES, "submitted")

    unless check_constraint_exists?(:pilot_feedback_reports, name: WORKFLOW_CONSTRAINT)
      add_check_constraint :pilot_feedback_reports,
        "workflow IN ('sign_in', 'home', 'setup', 'ask_mia', 'voice', 'budget', 'transaction_review', 'receipt_upload', 'statement_upload', 'document_upload', 'private_document', 'admin', 'other')",
        name: WORKFLOW_CONSTRAINT
    end

    unless check_constraint_exists?(:pilot_feedback_reports, name: STATUS_CONSTRAINT)
      add_check_constraint :pilot_feedback_reports,
        "status IN ('submitted', 'reviewed', 'resolved')",
        name: STATUS_CONSTRAINT
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "These constraints may predate this repair migration"
  end

  private

  def repair_invalid_values!(column, allowed, replacement)
    quoted_allowed = allowed.map { |value| connection.quote(value) }.join(", ")
    quoted_replacement = connection.quote(replacement)
    count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM pilot_feedback_reports
      WHERE #{column} IS NULL OR #{column} NOT IN (#{quoted_allowed})
    SQL
    say "Repairing #{count} pilot feedback #{column} value(s)" if count.positive?
    execute <<~SQL.squish
      UPDATE pilot_feedback_reports
      SET #{column} = #{quoted_replacement}, updated_at = CURRENT_TIMESTAMP
      WHERE #{column} IS NULL OR #{column} NOT IN (#{quoted_allowed})
    SQL
  end
end
