require "test_helper"

class ApiV1FinancialBaselinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "baseline-ui-#{SecureRandom.hex(8)}", email: "baseline-ui-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @baseline_request = { window_start_on: "2026-07-01", window_end_on: "2026-07-31", revision_ids: [], tracked_account_ids: [],
      household_scope_attested: false, cash_coverage: "unknown", category_eligibility: [] }
  end

  test "manual baseline preview remains unknown and approval replay does not duplicate history" do
    get "/api/v1/financial_baseline", headers: auth_headers
    assert_response :success
    assert_nil response.parsed_body.fetch("approved_version")
    post "/api/v1/financial_baseline/preview", params: { request: @baseline_request }, headers: auth_headers, as: :json
    assert_response :success
    preview = response.parsed_body
    refute preview.fetch("complete_eligible")
    refute preview.fetch("observed_spending_known")
    assert_empty preview.fetch("sample_rows")
    assert_empty FinancialBaselineVersion.where(household: @household)
    input = { request: @baseline_request, expected_preview_digest: preview.fetch("digest"), base_version_id: nil, base_lock_version: 0,
      coverage_status: "manual", reason: "I will start with limited manual context" }
    2.times do
      post "/api/v1/financial_baseline/approve", params: input, headers: auth_headers.merge("Idempotency-Key" => "manual-baseline"), as: :json
      assert_response :success
    end
    assert response.parsed_body.fetch("replayed")
    assert_equal 1, FinancialBaselineVersion.where(household: @household).count
    get "/api/v1/financial_baseline", headers: auth_headers
    assert_response :success
    assert_equal "manual", response.parsed_body.dig("approved_version", "coverage_status")
    refute response.parsed_body.fetch("needs_revision")
    assert_includes response.headers["Cache-Control"], "no-store"
    get "/api/v1/financial_baseline/history", headers: auth_headers
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("records").length
    assert_nil response.parsed_body.fetch("next_cursor")
    execution = @household.household_operation_executions.where(operation_key: "baseline.approve").sole
    assert_empty execution.normalized_input
    assert_not_includes execution.attributes.to_json, input[:reason]
  end

  test "changed preview or complete unknown request cannot publish financial truth" do
    post "/api/v1/financial_baseline/preview", params: { request: @baseline_request }, headers: auth_headers, as: :json
    digest = response.parsed_body.fetch("digest")
    input = { request: @baseline_request, expected_preview_digest: digest, base_version_id: nil, base_lock_version: 0, coverage_status: "complete", reason: "I checked this window" }
    post "/api/v1/financial_baseline/approve", params: input, headers: auth_headers.merge("Idempotency-Key" => "incomplete-baseline"), as: :json
    assert_response :unprocessable_entity
    input[:coverage_status] = "manual"
    input[:request] = @baseline_request.merge(window_start_on: "2026-06-01")
    post "/api/v1/financial_baseline/approve", params: input, headers: auth_headers.merge("Idempotency-Key" => "stale-baseline"), as: :json
    assert_response :conflict
    assert_empty FinancialBaselineVersion.where(household: @household)
  end

  test "private baseline paths reject coach admin and downgraded member access" do
    %w[coach admin].each do |role|
      @user.update!(role: role)
      %w[financial_baseline financial_baseline/history financial_baseline/context].each do |path|
        get "/api/v1/#{path}", headers: auth_headers
        assert_response :forbidden
      end
      post "/api/v1/financial_baseline/preview", params: { request: @baseline_request }, headers: auth_headers, as: :json
      assert_response :forbidden
    end
    @user.update!(role: "participant")
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    get "/api/v1/financial_baseline", headers: auth_headers
    assert_response :forbidden
    assert_empty FinancialBaselineVersion.where(household: @household)
  end

  test "Guam actor context and committed request recovery are scoped to the actual participant" do
    travel_to Time.utc(2026, 10, 5, 16, 1) do
      get "/api/v1/financial_baseline/context", headers: auth_headers
      assert_response :success
      assert_equal "2026-10-06", response.parsed_body.fetch("local_today")
      assert_equal({ "user_id" => @user.id, "household_id" => @household.id }, response.parsed_body.fetch("actor_scope"))
      get "/api/v1/financial_baseline/request_status?approval_action=approve", headers: auth_headers.merge("Idempotency-Key" => "recovery")
      assert_response :success
      assert_equal "unknown", response.parsed_body.fetch("state")
      post "/api/v1/financial_baseline/preview", params: { request: @baseline_request }, headers: auth_headers, as: :json
      input = { request: @baseline_request, expected_preview_digest: response.parsed_body.fetch("digest"), base_version_id: nil,
        base_lock_version: 0, coverage_status: "manual", reason: "Reviewed limited context" }
      post "/api/v1/financial_baseline/approve", params: input, headers: auth_headers.merge("Idempotency-Key" => "recovery"), as: :json
      assert_response :success
      version_id = response.parsed_body.dig("record", "id")
      get "/api/v1/financial_baseline/request_status?approval_action=approve", headers: auth_headers.merge("Idempotency-Key" => "recovery")
      assert_response :success
      assert_equal "committed", response.parsed_body.fetch("state")
      assert_equal version_id, response.parsed_body.dig("record", "id")
      get "/api/v1/financial_baseline/request_status?approval_action=revise", headers: auth_headers.merge("Idempotency-Key" => "recovery")
      assert_response :conflict
    end
  end

  test "observations validate dates and retain signed canonical distinctions" do
    get "/api/v1/financial_baseline/observations", headers: auth_headers
    assert_response :unprocessable_entity
    %w[actual purchase withdrawal].each do |kind|
      get "/api/v1/financial_baseline/observations", params: { kind: kind, window_start_on: "2026-07-01", window_end_on: "2026-07-31" }, headers: auth_headers
      assert_response :success
      assert_equal kind, response.parsed_body.fetch("kind")
      assert_empty response.parsed_body.fetch("records")
      assert_includes response.headers["Cache-Control"], "no-store"
    end
    @user.update!(role: "coach")
    get "/api/v1/financial_baseline/observations", headers: auth_headers
    assert_response :forbidden
    get "/api/v1/financial_baseline/request_status?approval_action=approve", headers: auth_headers.merge("Idempotency-Key" => "recovery")
    assert_response :forbidden
  end

  private

  def auth_headers = { "Authorization" => "Bearer test_token_#{@user.id}" }
end
