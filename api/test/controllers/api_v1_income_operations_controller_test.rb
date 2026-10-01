require "test_helper"

class ApiV1IncomeOperationsControllerTest < ActionDispatch::IntegrationTest
  test "income source endpoints preserve response contract and idempotency" do
    user = create_user
    headers = auth_headers(user).merge("Idempotency-Key" => "source-create")
    params = { income_source: { label: "Consulting", source_type: "business", amount: 1_250, cadence: "monthly", starts_on: "2026-10-15" } }

    2.times do
      post "/api/v1/income_sources?year=2026", params: params, headers: headers, as: :json
      assert_response :created
    end
    source_id = response.parsed_body.dig("income_source", "id")
    assert_equal 1, user.households.first.income_sources.where(label: "Consulting").count
    assert_equal "2026-10-01", response.parsed_body.dig("income_source", "starts_on")
    assert response.parsed_body.dig("budget", "annual_plan")

    delete "/api/v1/income_sources/#{source_id}?year=2026", params: { income_source: { ends_on: "2026-11-01" } }, headers: auth_headers(user).merge("Idempotency-Key" => "source-archive"), as: :json
    assert_response :success
    assert_equal "2026-11-01", response.parsed_body.dig("income_source", "ends_on")

    post "/api/v1/income_sources/#{source_id}/restore?year=2026", params: {}, headers: auth_headers(user).merge("Idempotency-Key" => "source-restore"), as: :json
    assert_response :success
    assert_nil response.parsed_body.dig("income_source", "ends_on")
  end

  test "schedule endpoints use ledgers and keep their existing payloads" do
    user = create_user
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    source = household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly")
    body = { income_schedule_entry: { income_source_id: source.id, entry_type: "one_time", label: "Bonus", amount: 400, effective_on: "2026-12-12" } }
    headers = auth_headers(user).merge("Idempotency-Key" => "bonus-create")

    2.times do
      post "/api/v1/income_schedule_entries?year=2026", params: body, headers: headers, as: :json
      assert_response :created
    end
    entry_id = response.parsed_body.dig("income_schedule_entry", "id")
    assert_equal "2026-12-01", response.parsed_body.dig("income_schedule_entry", "effective_on")
    assert_equal 1, source.income_schedule_entries.where(id: entry_id).count
    assert_equal 1, household.household_operation_executions.where(idempotency_key: "bonus-create").count

    delete "/api/v1/income_schedule_entries/#{entry_id}?year=2026", headers: auth_headers(user).merge("Idempotency-Key" => "bonus-delete"), as: :json
    assert_response :success
    assert_equal({ "id" => entry_id, "deleted" => true }, response.parsed_body.fetch("income_schedule_entry"))
  end

  test "income writes require an idempotency key" do
    user = create_user
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    source = household.income_sources.create!(label: "Salary", source_type: "job", amount_cents: 500_000, cadence: "monthly")

    post "/api/v1/income_sources", params: { income_source: { label: "Consulting", source_type: "business", amount: 1_000, cadence: "monthly" } }, headers: auth_headers(user), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Idempotency-Key header is required"
    refute household.income_sources.exists?(label: "Consulting")

    post "/api/v1/income_schedule_entries", params: { income_schedule_entry: { income_source_id: source.id, entry_type: "one_time", amount: 500, effective_on: "2026-12-01" } }, headers: auth_headers(user), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Idempotency-Key header is required"
    assert_empty source.income_schedule_entries
  end

  private

  def create_user
    User.create!(clerk_id: "income_controller_#{SecureRandom.hex(8)}", email: "income-controller-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
