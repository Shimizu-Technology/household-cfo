require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1PilotFeedbackSupportSharingTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  setup do
    setup_savings_context
    @admin = User.create!(clerk_id: SecureRandom.uuid, email: "support-#{SecureRandom.hex(6)}@example.com", role: "admin", invitation_status: "accepted")
    @partner = User.create!(clerk_id: SecureRandom.uuid, email: "partner-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
    @savings_household.household_memberships.create!(user: @partner, role: "partner")
  end

  test "pilot household requires explicit approval before enrollment and for household partners" do
    [ nil, false, "false", "0", "yes", 1 ].each do |approval|
      [ @savings_user, @partner ].each do |actor|
        assert_no_difference([ "PilotFeedbackReport.count", "HouseholdAuditEvent.count" ]) do
          post reports_path, params: input(approval), headers: auth(actor), as: :json
        end
        assert_response :unprocessable_entity
      end
    end
    assert_equal 0, SavingsEnrollment.count
  end

  test "approved report reaches administrators while legacy pilot reports and finances stay private" do
    post reports_path, params: input(true).deep_merge(feedback_report: { user_id: @admin.id, household_id: -1, support_sharing_policy_version: "forged" }), headers: auth(@savings_user), as: :json
    assert_response :created
    report = PilotFeedbackReport.last
    assert_equal @savings_user, report.user
    assert_equal @savings_household, report.household
    assert report.support_sharing_granted?
    assert_equal "technical_support_v1", report.support_sharing_policy_version
    assert response.parsed_body.dig("feedback_report", "support_access_available")
    refute response.parsed_body.fetch("feedback_report").key?("attempted")
    legacy = @savings_household.pilot_feedback_reports.create!(user: @partner, workflow: "home", attempted: "Legacy private", expected: "Private", actual: "Private")
    get "/api/v1/admin/pilot_feedback_reports?status=all", headers: auth(@admin)
    assert_response :success
    assert_equal [ report.id ], response.parsed_body.fetch("feedback_reports").pluck("id")
    assert_equal 1, response.parsed_body.dig("counts", "submitted")
    get "/api/v1/admin/pilot_feedback_reports/#{legacy.id}", headers: auth(@admin)
    assert_response :not_found
    get "/api/v1/admin/pilot_feedback_reports/#{report.id}", headers: auth(@admin)
    assert_response :success
    assert_equal "Open the technical help dialog", response.parsed_body.dig("feedback_report", "attempted")
    get "/api/v1/admin/pilot_feedback_reports/#{report.id}", headers: auth(@savings_owner)
    assert_response :forbidden
    assert_raises(ChallengePrivacy::PrivateFinanceAccess::Denied) { ChallengePrivacy::PrivateFinanceAccess.authorize!(@savings_household, user: @admin) }
    audit = HouseholdAuditEvent.where(event_type: "pilot_feedback_report.submitted").last
    assert_equal "report_text_and_optional_screenshot", audit.metadata.fetch("support_scope")
    refute_includes audit.metadata.to_json, report.attempted
  end

  test "withdrawal is author only idempotent and closes every staff report route" do
    report = shared_report
    report.update!(screenshot_s3_key: "private/test.png", screenshot_filename: "test.png", screenshot_content_type: "image/png", screenshot_byte_size: 25)
    patch "#{reports_path}/#{report.id}/withdraw_support_access", headers: auth(@partner), as: :json
    assert_response :not_found
    assert report.reload.support_sharing_granted?
    2.times do
      patch "#{reports_path}/#{report.id}/withdraw_support_access", headers: auth(@savings_user), as: :json
      assert_response :success
      refute response.parsed_body.dig("feedback_report", "support_access_available")
    end
    assert_equal 1, HouseholdAuditEvent.where(event_type: "pilot_feedback_report.support_access_withdrawn").count
    get "/api/v1/admin/pilot_feedback_reports?status=all", headers: auth(@admin)
    assert_response :success
    assert_empty response.parsed_body.fetch("feedback_reports")
    assert_equal 0, response.parsed_body.dig("counts", "submitted")
    [ "/api/v1/admin/pilot_feedback_reports/#{report.id}", "/api/v1/admin/pilot_feedback_reports/#{report.id}/screenshot_url" ].each do |path|
      get path, headers: auth(@admin)
      assert_response :not_found
    end
    patch "/api/v1/admin/pilot_feedback_reports/#{report.id}", params: { feedback_report: { status: "reviewed" } }, headers: auth(@admin), as: :json
    assert_response :not_found
    assert_equal "submitted", report.reload.status
  end

  test "metadata history is paginated and scoped to the authenticated author" do
    22.times { shared_report }
    other = shared_report(user: @partner)
    get reports_path, headers: auth(@savings_user)
    assert_response :success
    rows = response.parsed_body.fetch("feedback_reports")
    assert_equal 20, rows.size
    refute_includes rows.pluck("id"), other.id
    refute rows.any? { |row| row.key?("attempted") || row.key?("screenshot_s3_key") }
    get reports_path, params: { before_id: response.parsed_body.fetch("next_cursor") }, headers: auth(@savings_user)
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("feedback_reports").size
    assert_nil response.parsed_body.fetch("next_cursor")
    get reports_path, params: { before_id: "-1" }, headers: auth(@savings_user)
    assert_response :unprocessable_entity
  end

  test "ordinary legacy reports may be withdrawn too" do
    @savings_membership.destroy!
    legacy = @savings_household.pilot_feedback_reports.create!(user: @savings_user, workflow: "home", attempted: "Legacy", expected: "Legacy", actual: "Legacy")
    get "/api/v1/admin/pilot_feedback_reports/#{legacy.id}", headers: auth(@admin)
    assert_response :success
    patch "#{reports_path}/#{legacy.id}/withdraw_support_access", headers: auth(@savings_user), as: :json
    assert_response :success
    get "/api/v1/admin/pilot_feedback_reports/#{legacy.id}", headers: auth(@admin)
    assert_response :not_found
  end

  test "constraint rejects partial consent while legacy defaults remain private" do
    legacy = @savings_household.pilot_feedback_reports.create!(user: @savings_user, workflow: "home", attempted: "Legacy", expected: "Legacy", actual: "Legacy")
    refute legacy.support_sharing_granted?
    refute legacy.support_access_available?
    assert_raises(ActiveRecord::StatementInvalid) do
      PilotFeedbackReport.transaction(requires_new: true) { legacy.update_columns(support_sharing_approved_at: Time.current) }
    end
  end

  test "malformed envelopes return controlled errors without writes" do
    [ nil, "bad", [ "bad" ] ].each do |envelope|
      assert_no_difference([ "PilotFeedbackReport.count", "HouseholdAuditEvent.count" ]) do
        post reports_path, params: { feedback_report: envelope }, headers: auth(@savings_user), as: :json
      end
      assert_response :bad_request
    end
  end

  test "admin update rechecks sharing when withdrawal wins before the report lock" do
    report = shared_report
    original = PilotFeedbackReport.instance_method(:lock!)
    PilotFeedbackReport.define_method(:lock!) do |*args|
      if id == report.id && support_sharing_revoked_at.nil?
        self.class.where(id: id).update_all(support_sharing_revoked_at: Time.current)
      end
      original.bind_call(self, *args)
    end
    begin
      assert_no_difference("HouseholdAuditEvent.count") do
        patch "/api/v1/admin/pilot_feedback_reports/#{report.id}", params: { feedback_report: { status: "reviewed" } }, headers: auth(@admin), as: :json
      end
      assert_response :not_found
      refute_includes response.body, report.attempted
      assert_equal "submitted", report.reload.status
    ensure
      PilotFeedbackReport.define_method(:lock!, original)
    end
  end

  private
  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }
  def reports_path = "/api/v1/pilot_feedback_reports"
  def input(approval) = { feedback_report: { workflow: "home", attempted: "Open the technical help dialog", expected: "Readable controls", actual: "The button is too small", share_with_support: approval } }
  def shared_report(user: @savings_user)
    @savings_household.pilot_feedback_reports.create!(user: user, workflow: "home", attempted: "Technical problem", expected: "Readable controls", actual: "Small button",
      support_sharing_approved_at: Time.current, support_sharing_policy_version: PilotFeedbackReport::SUPPORT_SHARING_POLICY_VERSION)
  end
end
