require "test_helper"
require "base64"

class ApiV1PilotFeedbackReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      clerk_id: "clerk_feedback_user",
      email: "feedback-user@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "create requires authentication" do
    post "/api/v1/pilot_feedback_reports", params: valid_params, as: :json

    assert_response :unauthorized
  end

  test "create stores structured feedback in the authenticated household without returning private text" do
    assert_difference([ "PilotFeedbackReport.count", "HouseholdAuditEvent.count" ], 1) do
      post "/api/v1/pilot_feedback_reports", params: valid_params, headers: auth_headers(@user), as: :json
    end

    assert_response :created
    report = PilotFeedbackReport.last
    assert_equal @household, report.household
    assert_equal @user, report.user
    assert_equal "ask_mia", report.workflow
    assert_equal "I tried to record a purchase.", report.attempted

    body = JSON.parse(response.body).fetch("feedback_report")
    assert_equal false, body.fetch("screenshot_attached")
    assert_not body.key?("attempted")
    assert_not body.key?("expected")
    assert_not body.key?("actual")

    audit = HouseholdAuditEvent.last
    assert_equal "pilot_feedback_report.submitted", audit.event_type
    assert_equal({ "workflow" => "ask_mia", "screenshot_attached" => false }, audit.metadata)
  end

  test "create validates workflow and all three report details" do
    post "/api/v1/pilot_feedback_reports",
      params: { feedback_report: { workflow: "bank-account-1234", attempted: "", expected: "", actual: "" } },
      headers: auth_headers(@user),
      as: :json

    assert_response :unprocessable_entity
    errors = JSON.parse(response.body).fetch("errors").join(" ")
    assert_includes errors, "Workflow is not included"
    assert_includes errors, "Attempted can't be blank"
    assert_equal 0, PilotFeedbackReport.count
  end

  test "create stores an optional screenshot privately without exposing its key" do
    uploaded = []
    with_s3_stubs(
      configured?: true,
      upload: ->(key, io, content_type:) { uploaded << [ key, io.read, content_type ]; key }
    ) do
      post "/api/v1/pilot_feedback_reports",
        params: valid_params.merge(screenshot: uploaded_png),
        headers: auth_headers(@user)
    end

    assert_response :created
    report = PilotFeedbackReport.last
    assert report.screenshot?
    assert_match %r{/households/#{@household.id}/pilot-feedback/#{report.id}/pilot-screen\.png\z}, report.screenshot_s3_key
    assert_equal "image/png", report.screenshot_content_type
    assert_equal "image/png", uploaded.first.third

    body = JSON.parse(response.body).fetch("feedback_report")
    assert_equal true, body.fetch("screenshot_attached")
    assert_not body.key?("screenshot_s3_key")
    assert_not_includes response.body, report.screenshot_s3_key
  end

  test "failed private screenshot storage removes the report so submission can be retried safely" do
    with_s3_stubs(configured?: true, upload: nil) do
      assert_no_difference("PilotFeedbackReport.count") do
        post "/api/v1/pilot_feedback_reports",
          params: valid_params.merge(screenshot: uploaded_png),
          headers: auth_headers(@user)
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors").join, "not submitted"
    assert_equal 0, HouseholdAuditEvent.where(event_type: "pilot_feedback_report.submitted").count
  end

  test "create rejects disguised non-image screenshots" do
    with_s3_stubs(configured?: true) do
      post "/api/v1/pilot_feedback_reports",
        params: valid_params.merge(screenshot: uploaded_text_as_png),
        headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors").join, "does not match"
    assert_equal 0, PilotFeedbackReport.count
  end

  private

  def valid_params
    {
      feedback_report: {
        workflow: "ask_mia",
        attempted: "I tried to record a purchase.",
        expected: "I expected a draft to review.",
        actual: "The screen stayed on the loading state."
      }
    }
  end

  def uploaded_png
    file = Tempfile.new([ "pilot-screen", ".png" ])
    file.binmode
    file.write(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "pilot-screen.png")
  end

  def uploaded_text_as_png
    file = Tempfile.new([ "not-an-image", ".png" ])
    file.write("private account number 1234")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "not-an-image.png")
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
