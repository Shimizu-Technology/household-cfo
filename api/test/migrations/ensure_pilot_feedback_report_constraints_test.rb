require "test_helper"
require Rails.root.join("db/migrate/20260923040000_ensure_pilot_feedback_report_constraints").to_s

class EnsurePilotFeedbackReportConstraintsTest < ActiveSupport::TestCase
  test "repairs null and invalid legacy workflow and status values" do
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "feedback-migration-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(created_by_user: user, name: "Feedback migration household")
    null_report = create_report(household, user, "Null legacy values")
    invalid_report = create_report(household, user, "Invalid legacy values")
    connection = ActiveRecord::Base.connection

    connection.remove_check_constraint(:pilot_feedback_reports, name: EnsurePilotFeedbackReportConstraints::WORKFLOW_CONSTRAINT)
    connection.remove_check_constraint(:pilot_feedback_reports, name: EnsurePilotFeedbackReportConstraints::STATUS_CONSTRAINT)
    connection.change_column_null(:pilot_feedback_reports, :workflow, true)
    connection.change_column_null(:pilot_feedback_reports, :status, true)
    null_report.update_columns(workflow: nil, status: nil)
    invalid_report.update_columns(workflow: "legacy_workflow", status: "legacy_status")

    migration = EnsurePilotFeedbackReportConstraints.new
    ActiveRecord::Migration.suppress_messages do
      migration.send(:repair_invalid_values!, :workflow, EnsurePilotFeedbackReportConstraints::WORKFLOWS, "other")
      migration.send(:repair_invalid_values!, :status, EnsurePilotFeedbackReportConstraints::STATUSES, "submitted")
    end

    assert_equal [ "other", "submitted" ], null_report.reload.values_at(:workflow, :status)
    assert_equal [ "other", "submitted" ], invalid_report.reload.values_at(:workflow, :status)
  ensure
    restore_constraints if defined?(connection) && connection
  end

  private

  def create_report(household, user, attempted)
    household.pilot_feedback_reports.create!(
      user: user,
      workflow: "ask_mia",
      attempted: attempted,
      expected: "The migration should preserve a valid row.",
      actual: "The legacy row needs repair."
    )
  end

  def restore_constraints
    connection = ActiveRecord::Base.connection
    connection.execute <<~SQL.squish
      UPDATE pilot_feedback_reports
      SET workflow = 'other'
      WHERE workflow IS NULL OR workflow NOT IN ('sign_in', 'home', 'setup', 'ask_mia', 'voice', 'budget', 'transaction_review', 'receipt_upload', 'statement_upload', 'document_upload', 'private_document', 'admin', 'other')
    SQL
    connection.execute <<~SQL.squish
      UPDATE pilot_feedback_reports
      SET status = 'submitted'
      WHERE status IS NULL OR status NOT IN ('submitted', 'reviewed', 'resolved')
    SQL
    connection.change_column_null(:pilot_feedback_reports, :workflow, false)
    connection.change_column_null(:pilot_feedback_reports, :status, false)
    unless connection.check_constraint_exists?(:pilot_feedback_reports, name: EnsurePilotFeedbackReportConstraints::WORKFLOW_CONSTRAINT)
      connection.add_check_constraint(
        :pilot_feedback_reports,
        "workflow IN ('sign_in', 'home', 'setup', 'ask_mia', 'voice', 'budget', 'transaction_review', 'receipt_upload', 'statement_upload', 'document_upload', 'private_document', 'admin', 'other')",
        name: EnsurePilotFeedbackReportConstraints::WORKFLOW_CONSTRAINT
      )
    end
    return if connection.check_constraint_exists?(:pilot_feedback_reports, name: EnsurePilotFeedbackReportConstraints::STATUS_CONSTRAINT)

    connection.add_check_constraint(
      :pilot_feedback_reports,
      "status IN ('submitted', 'reviewed', 'resolved')",
      name: EnsurePilotFeedbackReportConstraints::STATUS_CONSTRAINT
    )
  end
end
