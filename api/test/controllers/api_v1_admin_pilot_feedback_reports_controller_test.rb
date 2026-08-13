require "test_helper"

class ApiV1AdminPilotFeedbackReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_user(email: "feedback-admin@example.com", role: "admin")
    @participant = create_user(email: "feedback-participant@example.com", role: "participant")
    @household = Household.create!(name: "Private Feedback Household", created_by_user: @participant)
    @household.household_memberships.create!(user: @participant, role: "owner")
    @report = @household.pilot_feedback_reports.create!(
      user: @participant,
      workflow: "ask_mia",
      attempted: "Upload a demo-safe budget spreadsheet",
      expected: "Mia should summarize the file",
      actual: "The upload returned a provider error"
    )
  end

  test "feedback inbox requires admin access" do
    get "/api/v1/admin/pilot_feedback_reports", headers: auth_headers(@participant)

    assert_response :forbidden
  end

  test "admin can list feedback summaries and counts without private narrative or storage keys" do
    reviewed = @household.pilot_feedback_reports.create!(
      user: @participant,
      workflow: "budget",
      attempted: "Change a category",
      expected: "The category should save",
      actual: "It saved after retrying",
      status: "reviewed"
    )

    get "/api/v1/admin/pilot_feedback_reports?status=all", headers: auth_headers(@admin)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal({ "submitted" => 1, "reviewed" => 1, "resolved" => 0 }, payload.fetch("counts"))
    assert_equal [ reviewed.id, @report.id ], payload.fetch("feedback_reports").map { |report| report.fetch("id") }
    row = payload.fetch("feedback_reports").last
    assert_equal "feedback-participant@example.com", row.dig("reporter", "email")
    assert_not row.key?("attempted")
    assert_not row.key?("actual")
    assert_not response.body.include?("screenshot_s3_key")
    assert_not response.body.include?("Private Feedback Household")
  end

  test "admin list defaults to submitted reports and supports status filtering" do
    @report.update!(status: "resolved")
    submitted = @household.pilot_feedback_reports.create!(
      user: @participant,
      workflow: "setup",
      attempted: "Save setup",
      expected: "Setup should save",
      actual: "Setup saved"
    )

    get "/api/v1/admin/pilot_feedback_reports", headers: auth_headers(@admin)

    assert_response :success
    assert_equal [ submitted.id ], JSON.parse(response.body).fetch("feedback_reports").map { |report| report.fetch("id") }

    get "/api/v1/admin/pilot_feedback_reports?status=resolved", headers: auth_headers(@admin)

    assert_response :success
    assert_equal [ @report.id ], JSON.parse(response.body).fetch("feedback_reports").map { |report| report.fetch("id") }
  end

  test "invalid list status is rejected" do
    get "/api/v1/admin/pilot_feedback_reports?status=deleted", headers: auth_headers(@admin)

    assert_response :unprocessable_entity
    assert_equal [ "Feedback status is not valid" ], JSON.parse(response.body).fetch("errors")
  end

  test "admin can read feedback detail without receiving the private storage key" do
    @report.update!(
      screenshot_s3_key: "private/households/1/feedback.png",
      screenshot_filename: "feedback.png",
      screenshot_content_type: "image/png",
      screenshot_byte_size: 1_024
    )

    get "/api/v1/admin/pilot_feedback_reports/#{@report.id}", headers: auth_headers(@admin)

    assert_response :success
    detail = JSON.parse(response.body).fetch("feedback_report")
    assert_equal "Upload a demo-safe budget spreadsheet", detail.fetch("attempted")
    assert_equal "feedback.png", detail.dig("screenshot", "filename")
    assert_not response.body.include?("private/households/1/feedback.png")
  end

  test "admin can move feedback through the review workflow with an audit event" do
    assert_difference("HouseholdAuditEvent.count", 1) do
      patch "/api/v1/admin/pilot_feedback_reports/#{@report.id}",
            params: { feedback_report: { status: "reviewed" } },
            headers: auth_headers(@admin),
            as: :json
    end

    assert_response :success
    assert_equal "reviewed", @report.reload.status
    audit = HouseholdAuditEvent.order(:id).last
    assert_equal "pilot_feedback_report.status_changed", audit.event_type
    assert_equal @admin, audit.user
    assert_equal({ "previous_status" => "submitted", "status" => "reviewed" }, audit.metadata)
  end

  test "saving the current status is idempotent and does not add an audit event" do
    assert_no_difference("HouseholdAuditEvent.count") do
      patch "/api/v1/admin/pilot_feedback_reports/#{@report.id}",
            params: { feedback_report: { status: "submitted" } },
            headers: auth_headers(@admin),
            as: :json
    end

    assert_response :success
  end

  test "invalid status update is rejected without changing the report" do
    assert_no_difference("HouseholdAuditEvent.count") do
      patch "/api/v1/admin/pilot_feedback_reports/#{@report.id}",
            params: { feedback_report: { status: "deleted" } },
            headers: auth_headers(@admin),
            as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "submitted", @report.reload.status
  end

  test "status update rolls back when its audit event cannot be recorded" do
    reject_status_audit = lambda do |audit_event|
      if audit_event.event_type == "pilot_feedback_report.status_changed"
        audit_event.errors.add(:base, "Forced feedback audit failure")
      end
    end
    HouseholdAuditEvent.set_callback(:validation, :before, reject_status_audit)

    assert_no_difference("HouseholdAuditEvent.count") do
      patch "/api/v1/admin/pilot_feedback_reports/#{@report.id}",
            params: { feedback_report: { status: "reviewed" } },
            headers: auth_headers(@admin),
            as: :json
    end

    assert_response :service_unavailable
    assert_equal "submitted", @report.reload.status
    assert_not response.body.include?("Forced feedback audit failure")
  ensure
    HouseholdAuditEvent.skip_callback(:validation, :before, reject_status_audit) if reject_status_audit
  end

  test "status update requires the feedback report envelope" do
    patch "/api/v1/admin/pilot_feedback_reports/#{@report.id}",
          params: { status: "reviewed" },
          headers: auth_headers(@admin),
          as: :json

    assert_response :unprocessable_entity
    assert_equal [ "Feedback status is required" ], JSON.parse(response.body).fetch("errors")
    assert_equal "submitted", @report.reload.status
  end

  test "admin can request short lived screenshot links without exposing the storage key" do
    @report.update!(
      screenshot_s3_key: "private/households/1/feedback.png",
      screenshot_filename: "feedback.png",
      screenshot_content_type: "image/png",
      screenshot_byte_size: 1_024
    )
    generated_urls = [ "https://signed.example/inline", "https://signed.example/download" ]

    with_s3_stubs(
      configured?: true,
      presigned_url: ->(*) { generated_urls.shift }
    ) do
      get "/api/v1/admin/pilot_feedback_reports/#{@report.id}/screenshot_url", headers: auth_headers(@admin)
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "https://signed.example/inline", payload.fetch("url")
    assert_equal "https://signed.example/download", payload.fetch("download_url")
    assert_equal 300, payload.fetch("expires_in")
    assert_not response.body.include?("private/households/1/feedback.png")
  end

  test "screenshot link reports missing screenshots and missing storage safely" do
    get "/api/v1/admin/pilot_feedback_reports/#{@report.id}/screenshot_url", headers: auth_headers(@admin)

    assert_response :not_found

    @report.update!(
      screenshot_s3_key: "private/households/1/feedback.png",
      screenshot_filename: "feedback.png",
      screenshot_content_type: "image/png",
      screenshot_byte_size: 1_024
    )

    with_s3_stubs(configured?: false) do
      get "/api/v1/admin/pilot_feedback_reports/#{@report.id}/screenshot_url", headers: auth_headers(@admin)
    end

    assert_response :service_unavailable
    assert_not response.body.include?("private/households/1/feedback.png")
  end

  test "feedback detail returns a json not found response" do
    get "/api/v1/admin/pilot_feedback_reports/999999", headers: auth_headers(@admin)

    assert_response :not_found
    assert_includes response.media_type, "application/json"
  end

  private

  def create_user(email:, role:)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: email,
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def with_s3_stubs(stubs)
    originals = {}
    singleton = class << S3Service; self; end
    stubs.each do |method_name, replacement|
      originals[method_name] = singleton.instance_method(method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name) do |*args, **kwargs, &block|
        replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
      end
    end
    yield
  ensure
    stubs.each_key do |method_name|
      singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name, originals[method_name]) if originals[method_name]
    end
  end
end
