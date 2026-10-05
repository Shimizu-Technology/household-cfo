class AddPilotFeedbackSupportSharing < ActiveRecord::Migration[8.1]
  def change
    add_column :pilot_feedback_reports, :support_sharing_approved_at, :datetime
    add_column :pilot_feedback_reports, :support_sharing_revoked_at, :datetime
    add_column :pilot_feedback_reports, :support_sharing_policy_version, :string
    add_check_constraint :pilot_feedback_reports,
      "(support_sharing_approved_at IS NULL AND support_sharing_policy_version IS NULL) OR (support_sharing_approved_at IS NOT NULL AND support_sharing_policy_version IS NOT NULL AND support_sharing_policy_version = 'technical_support_v1' AND (support_sharing_revoked_at IS NULL OR support_sharing_revoked_at >= support_sharing_approved_at))",
      name: "pilot_feedback_support_sharing_consistent"
  end
end
