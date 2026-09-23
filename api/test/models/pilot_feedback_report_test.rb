require "test_helper"

class PilotFeedbackReportTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "pilot-feedback-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(created_by_user: @user, name: "Pilot Feedback Household")
  end

  test "database rejects a workflow outside the application allowlist" do
    report = create_report

    assert_raises(ActiveRecord::StatementInvalid) do
      report.update_column(:workflow, "unsupported_workflow")
    end
  end

  test "database rejects a status outside the application allowlist" do
    report = create_report

    assert_raises(ActiveRecord::StatementInvalid) do
      report.update_column(:status, "unsupported_status")
    end
  end

  test "database accepts every application workflow and status" do
    PilotFeedbackReport::WORKFLOWS.product(PilotFeedbackReport::STATUSES).each do |workflow, status|
      report = create_report
      report.update_columns(workflow: workflow, status: status)
      assert_equal workflow, report.reload.workflow
      assert_equal status, report.status
      report.destroy!
    end
  end

  private

  def create_report
    @household.pilot_feedback_reports.create!(
      user: @user,
      workflow: "ask_mia",
      attempted: "I tried to record a purchase.",
      expected: "I expected a draft to review.",
      actual: "The request did not finish."
    )
  end
end
