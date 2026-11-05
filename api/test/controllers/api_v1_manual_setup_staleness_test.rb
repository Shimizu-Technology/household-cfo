require "test_helper"

class ApiV1ManualSetupStalenessTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "w18-#{SecureRandom.hex(6)}", email: "w18-#{SecureRandom.hex(6)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @headers = { "Authorization" => "Bearer test_token_#{@user.id}" }
  end

  test "two sessions cannot overwrite newer approved starting numbers and can recover by reviewing them" do
    first = open_session
    second = open_session
    [ first, second ].each { |session| session.get "/api/v1/workspace", headers: @headers }
    revision = first.response.parsed_body.dig("workspace", "setup_revision")
    assert_match(/\A[0-9a-f]{64}\z/, revision)
    assert_equal revision, second.response.parsed_body.dig("workspace", "setup_revision")

    headers = @headers.merge("X-Setup-Revision" => revision, "Idempotency-Key" => "first-device")
    first.patch "/api/v1/workspace/setup", params: { workspace: { primary_income: 5_200, household_name: "Newer approved name" } }, headers: headers, as: :json
    assert_equal 200, first.response.status
    assert_equal 5200, first.response.parsed_body.dig("workspace", "setup_values", "primary_income")

    assert_no_difference -> { @household.household_operation_executions.count } do
      second.patch "/api/v1/workspace/setup", params: { workspace: { primary_income: 4_000, household_name: "Old device name" } },
        headers: headers.merge("Idempotency-Key" => "stale-device"), as: :json
    end
    assert_equal 409, second.response.status
    assert_equal "changed_elsewhere", second.response.parsed_body["code"]
    assert_includes second.response.parsed_body["errors"].join, "Please look"
    assert_equal "Newer approved name", @household.reload.name
    assert_equal 520_000, @household.income_sources.sole.amount_cents

    second.get "/api/v1/workspace", headers: @headers
    latest = second.response.parsed_body.dig("workspace", "setup_revision")
    refute_equal revision, latest
    second.patch "/api/v1/workspace/setup", params: { workspace: { primary_income: 5_400 } },
      headers: headers.merge("X-Setup-Revision" => latest, "Idempotency-Key" => "reviewed-device"), as: :json
    assert_equal 200, second.response.status
    assert_equal 540_000, @household.income_sources.sole.income_schedule_entries.sole.amount_cents
    assert_no_difference -> { @household.household_operation_executions.count } do
      second.patch "/api/v1/workspace/setup", params: { workspace: { primary_income: 5_400 } },
        headers: headers.merge("X-Setup-Revision" => latest, "Idempotency-Key" => "reviewed-device"), as: :json
    end
    assert_equal 200, second.response.status
  end

  test "an old client without a before-state fails closed rather than overwriting values" do
    patch "/api/v1/workspace/setup", params: { workspace: { household_name: "Unreviewed" } },
      headers: @headers.merge("Idempotency-Key" => "no-revision"), as: :json
    assert_response :conflict
    assert_equal "changed_elsewhere", response.parsed_body["code"]
    refute_equal "Unreviewed", @household.reload.name
  end
end
