require "test_helper"
require_relative "../support/coach_launch_test_helper"

class ApiV1AdminCoachLaunchesControllerTest < ActionDispatch::IntegrationTest
  include CoachLaunchTestHelper
  setup { prepare_launch }

  test "HTTP launch and resolution return the same saved groups without a second publication" do
    post launch_path, params: { review: @review }, headers:, as: :json
    assert_response :success
    result = response.parsed_body.fetch("launch")
    assert_no_difference [ "CoachLaunchReceipt.count", "CohortRelease.count" ] do
      post resolve_path, params: { review: @review }, headers:, as: :json
      assert_response :success
      assert_equal "live", response.parsed_body.fetch("status")
      assert_equal result, response.parsed_body.fetch("launch")
    end
  end

  test "HTTP negative resolution fences the key and exposes a plain closed-request error to a delayed launch" do
    post resolve_path, params: { review: @review }, headers:, as: :json
    assert_response :success
    assert_equal "not_committed", response.parsed_body.fetch("status")
    refute response.parsed_body.key?("launch")
    assert_no_difference [ "CoachPersonaVersion.count", "CohortRelease.count" ] do
      post launch_path, params: { review: @review }, headers:, as: :json
      assert_response :conflict
    end
    refute_includes response.body, "PG::"
  end

  test "resolution requires current program publication authority and cannot close another actor's request" do
    post launch_path, params: { review: @review }, headers:, as: :json
    assert_response :success
    @workspace.coach_workspace_memberships.find_by!(user: @owner).update!(role: "editor")
    assert_no_difference "CoachLaunchReceipt.count" do
      post resolve_path, params: { review: @review }, headers:, as: :json
      assert_response :forbidden
    end
    refute_includes response.body, "Nothing"
  end

  test "database commit exceptions return a plain recovery response rather than an unhandled server error" do
    original = CoachLaunches::Publisher.instance_method(:call!)
    CoachLaunches::Publisher.define_method(:call!) { raise ActiveRecord::StatementInvalid, "PG::private detail" }
    post launch_path, params: { review: @review }, headers:, as: :json
    assert_response :conflict
    assert_includes response.parsed_body.fetch("error"), "Check this update"
    refute_includes response.body, "private detail"
  ensure
    CoachLaunches::Publisher.define_method(:call!, original) if original
  end

  private

  def launch_path = "/api/v1/admin/personas/#{@persona.id}/go_live"
  def resolve_path = "/api/v1/admin/personas/#{@persona.id}/resolve_go_live"
  def headers
    { "Authorization" => "Bearer test_token_#{@owner.id}", "X-Coach-Workspace-Id" => @workspace.id.to_s, "Idempotency-Key" => "controller-launch" }
  end
end
