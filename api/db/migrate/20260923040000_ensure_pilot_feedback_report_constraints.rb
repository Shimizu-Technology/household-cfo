class EnsurePilotFeedbackReportConstraints < ActiveRecord::Migration[8.1]
  WORKFLOW_CONSTRAINT = "pilot_feedback_reports_workflow_valid"
  STATUS_CONSTRAINT = "pilot_feedback_reports_status_valid"

  def up
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
end
