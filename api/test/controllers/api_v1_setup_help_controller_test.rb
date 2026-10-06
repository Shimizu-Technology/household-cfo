require "test_helper"

class ApiV1SetupHelpControllerTest < ActionDispatch::IntegrationTest
  setup do
    suffix = SecureRandom.hex(6)
    @user = User.create!(clerk_id: "setup-ui-#{suffix}", email: "setup-ui-#{suffix}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @admin = User.create!(clerk_id: "setup-admin-#{suffix}", email: "setup-admin-#{suffix}@example.com", role: "admin", invitation_status: "accepted")
  end

  test "own eligibility and self restart preserve exact receipt across a stale tab" do
    get "/api/v1/setup_help", headers: auth
    assert_response :success
    assert_equal true, response.parsed_body.dig("setup_help", "self_restart_available")
    assert_includes response.headers["Cache-Control"], "private, no-store"
    post "/api/v1/setup_help/restart/preview", headers: auth, as: :json
    assert_response :created
    id = response.parsed_body.dig("financial_restart", "review", "id")
    post "/api/v1/setup_help/restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal "1", response.headers["X-Financial-Generation"]
    get "/api/v1/setup_help/restart/status", params: { review_id: id }, headers: auth
    assert_response :success
    assert_equal "applied", response.parsed_body.dig("financial_restart", "latest_review", "status")
    post "/api/v1/setup_help/restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth.merge("X-Financial-Generation" => "0"), as: :json
    assert_response :success
    assert_equal 1, @household.reload.financial_generation
    post "/api/v1/setup_help/restart/preview", headers: auth.merge("X-Financial-Generation" => "0"), as: :json
    assert_response :conflict
    assert_equal "financial_generation_stale", response.parsed_body["code"]
  end

  test "saved zero values block direct restart while corrections stay available" do
    @household.update!(confirmed_setup_fields: [ "primary_income" ])
    get "/api/v1/setup_help", headers: auth
    assert_response :success
    assert_equal false, response.parsed_body.dig("setup_help", "self_restart_available")
    post "/api/v1/setup_help/restart/preview", headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, @household.reload.financial_generation
    post "/api/v1/income_sources", params: { income_source: { label: "Real job", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth, as: :json
    assert_response :created
  end

  test "participants request support admin prepares private snapshot participant confirms and staff sees metadata only" do
    @household.income_sources.create!(label: "Private employer", source_type: "job", cadence: "monthly", amount_cents: 876_543)
    create_request
    first = response.parsed_body["request"]
    assert_equal "none", first["review_state"]
    get "/api/v1/setup_support_requests", headers: auth(@admin)
    assert_response :success
    assert_includes response.parsed_body["records"].map { |item| item["id"] }, first["id"]
    refute_match(/Private employer|876543|inventory|previous_setup|fingerprint/, response.body)
    post "/api/v1/setup_support_requests/#{first['id']}/prepare", params: { expected_lock_version: first["lock_version"] }, headers: auth(@admin), as: :json
    assert_response :success
    ready = response.parsed_body["request"]
    assert_equal "pending", ready["review_state"]
    refute_match(/Private employer|876543|inventory|previous_setup|fingerprint/, response.body)
    assert_equal 0, @household.reload.financial_generation
    post "/api/v1/setup_help/restart/preview", params: { request_id: first["id"] }, headers: auth, as: :json
    assert_response :created
    assert_equal ready["review_id"], response.parsed_body.dig("financial_restart", "review", "id")
    post "/api/v1/setup_help/restart/apply", params: { request_id: first["id"], review_id: ready["review_id"], confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.financial_generation
    get "/api/v1/setup_help", headers: auth
    assert_response :success
    assert_equal "applied", response.parsed_body.dig("setup_help", "latest_request", "status")
    assert_equal "applied", response.parsed_body.dig("setup_help", "latest_request", "review_state")
  end

  test "participant cannot use staff queue or administrator test endpoint and coach personal reset has safe facade" do
    create_request
    request = response.parsed_body["request"]
    get "/api/v1/setup_support_requests", headers: auth
    assert_response :forbidden
    post "/api/v1/setup_support_requests/#{request['id']}/prepare", params: { expected_lock_version: 0 }, headers: auth, as: :json
    assert_response :forbidden
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    assert_response :forbidden
    @user.update!(role: "coach")
    get "/api/v1/setup_help", headers: auth
    assert_response :success
    assert_equal true, response.parsed_body.dig("setup_help", "self_restart_available")
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    assert_response :forbidden
  end

  test "request writes validate sharing idempotency enums and exact version" do
    post "/api/v1/setup_help/requests", params: { reason: "other", share_metadata: true }, headers: auth.except("Idempotency-Key"), as: :json
    assert_response :unprocessable_entity
    post "/api/v1/setup_help/requests", params: { reason: "My private bank statement text", share_metadata: true }, headers: auth, as: :json
    assert_response :unprocessable_entity
    create_request(key: "same-request")
    assert_response :created
    first = response.parsed_body["request"]
    create_request(key: "same-request", reason: "wrong_setup")
    assert_response :conflict
    post "/api/v1/setup_help/requests/#{first['id']}/cancel", params: { expected_lock_version: "0" }, headers: auth, as: :json
    assert_response :conflict
    post "/api/v1/setup_help/requests/#{first['id']}/cancel", params: { expected_lock_version: first["lock_version"] }, headers: auth, as: :json
    assert_response :success
    assert_equal "canceled", response.parsed_body.dig("request", "status")
  end

  test "owner reopens stale or expired prepared request and old review cannot apply" do
    create_request
    first = response.parsed_body["request"]
    post "/api/v1/setup_support_requests/#{first['id']}/prepare", params: { expected_lock_version: 0 }, headers: auth(@admin), as: :json
    ready = response.parsed_body["request"]
    @household.income_sources.create!(label: "New concurrent source", source_type: "job", cadence: "monthly", amount_cents: 200_000)
    post "/api/v1/setup_help/restart/apply", params: { review_id: ready["review_id"], request_id: first["id"], confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :conflict
    post "/api/v1/setup_help/requests/#{first['id']}/reopen", params: { expected_lock_version: ready["lock_version"] }, headers: auth, as: :json
    assert_response :success
    reopened = response.parsed_body["request"]
    assert_equal "in_review", reopened["status"]
    assert_nil reopened["review_id"]
    assert_equal "none", reopened["review_state"]
    post "/api/v1/setup_help/restart/preview", params: { request_id: first["id"] }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, @household.reload.financial_generation
  end

  test "Mia reset intent and Everything continuation surface guided setup help without creating records" do
    [ "These are practice numbers. Reset all my information and start over", "Everything", "All the information that I have" ].each_with_index do |message, index|
      assert_no_difference [ "FinancialRestartReview.count", "SetupSupportRequest.count", "IncomeSource.count" ] do
        post "/api/v1/mia/messages", params: { message: message, request_id: "setup-routing-#{index}" }, headers: auth, as: :json
      end
      assert_response :created
      assert_equal true, response.parsed_body.dig("setup_help", "available")
      assert_equal true, response.parsed_body.dig("assistant_message", "setup_help", "available")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "Fix my setup"
    end
    get "/api/v1/mia/messages", headers: auth
    assert_response :success
    assert response.parsed_body["messages"].select { |message| message["role"] == "assistant" }.all? { |message| message.dig("setup_help", "available") == true }
    delete "/api/v1/mia/messages", headers: auth
    assert_response :no_content
    post "/api/v1/mia/messages", params: { message: "Everything", request_id: "unrelated-everything" }, headers: auth, as: :json
    assert_response :created
    assert_nil response.parsed_body["setup_help"]
  end

  test "retained conversation history strips setup actions and remains private" do
    post "/api/v1/mia/messages", params: { message: "Start over", request_id: "private-reset-prompt" }, headers: auth, as: :json
    assert_response :created
    post "/api/v1/setup_help/restart/preview", headers: auth, as: :json
    id = response.parsed_body.dig("financial_restart", "review", "id")
    post "/api/v1/setup_help/restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    get "/api/v1/mia/messages", params: { picture: "history" }, headers: auth
    assert_response :success
    assert response.parsed_body["messages"].all? { |message| message["setup_help"].nil? && message["read_only"] }
    get "/api/v1/mia/messages", headers: auth(@admin)
    assert_response :success
    refute_includes response.body, "private-reset-prompt"
  end

  private
  def auth(user = @user)
    { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => SecureRandom.uuid }
  end
  def create_request(key: SecureRandom.uuid, reason: "practice_numbers")
    post "/api/v1/setup_help/requests", params: { reason: reason, share_metadata: true }, headers: auth.merge("Idempotency-Key" => key), as: :json
  end
end
