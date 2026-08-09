class CreatePilotFeedbackReports < ActiveRecord::Migration[8.1]
  def change
    create_table :pilot_feedback_reports do |t|
      t.references :household, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :workflow, null: false
      t.text :attempted, null: false
      t.text :expected, null: false
      t.text :actual, null: false
      t.string :status, null: false, default: "submitted"
      t.string :screenshot_s3_key
      t.string :screenshot_filename
      t.string :screenshot_content_type
      t.bigint :screenshot_byte_size

      t.timestamps

      t.check_constraint "workflow IN ('sign_in', 'home', 'setup', 'ask_mia', 'voice', 'budget', 'transaction_review', 'receipt_upload', 'statement_upload', 'document_upload', 'private_document', 'admin', 'other')",
        name: "pilot_feedback_reports_workflow_valid"
      t.check_constraint "status IN ('submitted', 'reviewed', 'resolved')",
        name: "pilot_feedback_reports_status_valid"
    end

    add_index :pilot_feedback_reports, %i[status created_at]
  end
end
